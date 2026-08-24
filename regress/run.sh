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
# The bash server both engines need is started (and stopped) by this
# script itself.  It MUST live in the same environment as the runs --
# bash_process expands "$NUNCHAKU_HOME" on the server side, so a server
# started from the real home would silently run the distribution's
# bundled 2017 binary instead of the component under test.
#
# The script bootstraps an isolated ISABELLE_HOME_USER under <workdir>:
# it COPIES the real ~/.isabelle preferences first (a scratch user dir
# with default preferences can silently flip ML_system_64 and trigger an
# implicit 32-bit build), registers the component, and keeps heaps in
# <workdir>/heaps.  It never runs "isabelle build".
set -eu

REGRESS="$(cd "$(dirname "$0")" && pwd)"
WORK=${1:?usage: run.sh <workdir>}
ISA=${ISABELLE:-isabelle}
COMP=${NUNCHAKU_COMPONENT:-$(cd "$REGRESS/.." && pwd)/component}
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

[ -x "$COMP/x86_64-linux/nunchaku" ] || {
  echo "run.sh: no executable $COMP/x86_64-linux/nunchaku" >&2; exit 1; }

ISA_ID=$("$ISA" getenv -b ISABELLE_IDENTIFIER)
REAL_PREFS="$HOME/.isabelle/$ISA_ID/etc/preferences"
FAKE_ETC="$WORK/fakehome/.isabelle/$ISA_ID/etc"
if [ ! -f "$FAKE_ETC/preferences" ]; then
  [ -f "$REAL_PREFS" ] || {
    echo "run.sh: $REAL_PREFS not found; refusing to run with default preferences" >&2
    exit 1; }
  mkdir -p "$FAKE_ETC"
  cp "$REAL_PREFS" "$FAKE_ETC/preferences"
fi
printf 'ISABELLE_HEAPS="%s"\n' "$WORK/heaps" > "$FAKE_ETC/settings"
printf '%s\n' "$COMP" > "$FAKE_ETC/components"

export USER_HOME="$WORK/fakehome" HOME="$WORK/fakehome"

ML64=$("$ISA" options -g ML_system_64)
[ "$ML64" = true ] || { echo "run.sh: ML_system_64=$ML64 (want true); aborting" >&2; exit 1; }
NUNHOME=$("$ISA" getenv -b NUNCHAKU_HOME)
[ "$NUNHOME" = "$COMP/x86_64-linux" ] || {
  echo "run.sh: NUNCHAKU_HOME=$NUNHOME does not point at $COMP/x86_64-linux" >&2; exit 1; }
NUNVER=$("$ISA" getenv -b NUNCHAKU_VERSION)
[ "$NUNVER" = "$(cat "$REGRESS/../VERSION")" ] || {
  echo "run.sh: NUNCHAKU_VERSION=$NUNVER does not match VERSION ($(cat "$REGRESS/../VERSION"))" >&2
  echo "        (was @NUNCHAKU_VERSION@ substituted when the component was assembled?)" >&2
  exit 1; }

rm -f "$WORK/bash_server_addr.txt"
"$ISA" scala "$REGRESS/bash_server_main.scala" "$WORK/bash_server_addr.txt" \
  > "$WORK/bash_server.log" 2>&1 &
BS_PID=$!
trap 'kill "$BS_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 180); do
  grep -q BASH_SERVER_READY "$WORK/bash_server.log" 2>/dev/null && break
  kill -0 "$BS_PID" 2>/dev/null || break
  sleep 1
done
grep -q BASH_SERVER_READY "$WORK/bash_server.log" || {
  echo "run.sh: bash server failed to start, see $WORK/bash_server.log" >&2; exit 1; }
ADDR=$(sed -n 1p "$WORK/bash_server_addr.txt")
PW=$(sed -n 2p "$WORK/bash_server_addr.txt")

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
