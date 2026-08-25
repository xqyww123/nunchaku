#!/usr/bin/env bash
# Usage: run.sh <workdir> [gold]
#
# Runs the gold smoke test (NunGold.thy) and then the full benchmark
# (78 goals: bench.ML over Main + bench2.ML over DTBench) against the
# component under test, aggregating the RESULT lines into
# <workdir>/results.tsv, results_datatypes.tsv and summaries.
# With "gold" as second argument, stops after the gold test.
#
# Prerequisites (see README.md):
#   - $NUNCHAKU_COMPONENT points at the component to test
#     (default: ../component next to this script -- only valid once the
#     packaging artifacts have been dropped into it)
#   - $ISABELLE names the isabelle executable (default: isabelle in PATH)
#
# The isolated ISABELLE_HOME_USER under <workdir>, the component
# registration and the bash server both engines need all come from
# lib_bootstrap.sh, which tools/capture.sh sources too; the reasons each
# step is there are written down in that file.  Nothing here ever runs
# "isabelle build".
set -eu

REGRESS="$(cd "$(dirname "$0")" && pwd)"
WORK=${1:?usage: run.sh <workdir>}
ISA=${ISABELLE:-isabelle}
COMP=${NUNCHAKU_COMPONENT:-$(cd "$REGRESS/.." && pwd)/component}
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

. "$REGRESS/lib_bootstrap.sh"
isabelle_env
bash_server

# run one -e expression in a HOL ML_process, logging output
run_isa () { # <ml-expression> <logfile>
  "$ISA" ML_process -l HOL -C "$REGRESS" \
    -o bash_process_address="$ADDR" -o bash_process_password="$PW" \
    -e "$1" > "$2" 2>&1
}

# run one ML file in a HOL ML_process (theory context Main), logging RESULT lines
run_ml () { # <ml-file> <logfile>
  run_isa 'Context.setmp_generic_context (SOME (Context.Theory (Thy_Info.get_theory "Main"))) (fn () => ML_Context.eval_file ML_Compiler.flags (Path.explode "'"$1"'")) ()' "$2"
}

run_arm () { # <ml-file> <prefix> <engine> <tier>
  echo "ARM_START $2 $3 $4 $(date +%T)"
  local rc=0
  BENCH_ENGINE=$3 BENCH_TIER=$4 run_ml "$REGRESS/$1" "$WORK/${2}_${3}_${4}.log" || rc=$?
  echo "ARM_END $2 $3 $4 rc=$rc results=$(grep -c '^RESULT' "$WORK/${2}_${3}_${4}.log" || true) $(date +%T)"
}

# gold smoke test first: fail fast before spending ~30 min on the arms
echo "GOLD_START $(date +%T)"
run_ml_gold_rc=0
run_isa 'Thy_Info.use_thy_legacy "NunGold"' "$WORK/gold.log" || run_ml_gold_rc=$?
if ! grep -q GOLD_OK "$WORK/gold.log"; then
  echo "GOLD FAIL (rc=$run_ml_gold_rc), see $WORK/gold.log:" >&2
  tail -5 "$WORK/gold.log" >&2
  exit 1
fi
echo "GOLD_OK $(date +%T)"
[ "${2:-}" = gold ] && exit 0

for tier in 1 5; do
  for engine in nitpick nunchaku nunchaku_smbc nunchaku_ship; do
    run_arm bench.ML  out  $engine $tier
    run_arm bench2.ML out2 $engine $tier
  done
done
echo "ALL_ARMS_DONE"

# side-checks (report-only for UNPROVED): the truth labels the gate's
# hardest rule rests on, and the DTBench sanity theory
echo "TRUTHCHECK_START $(date +%T)"
run_ml "$REGRESS/truthcheck.ML" "$WORK/truthcheck.log" || true
echo "TRUTHCHECK unproved=$(grep -c 'UNPROVED' "$WORK/truthcheck.log" || true) (report only, see truthcheck.log)"
run_isa 'Thy_Info.use_thy_legacy "DTBenchCheck"; writeln "DTBENCHCHECK_OK"' "$WORK/out_dtbenchcheck.log" || true
grep -q DTBENCHCHECK_OK "$WORK/out_dtbenchcheck.log" || {
  echo "run.sh: DTBenchCheck failed to load, see $WORK/out_dtbenchcheck.log" >&2; exit 1; }
echo "DTBENCHCHECK_OK"

python3 "$REGRESS/aggregate.py" "$WORK" out_  results.tsv           > "$WORK/summary.txt"
python3 "$REGRESS/aggregate.py" "$WORK" out2_ results_datatypes.tsv > "$WORK/summary_datatypes.txt"
echo "results: $WORK/results.tsv $WORK/results_datatypes.tsv"
