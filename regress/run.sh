#!/usr/bin/env bash
# Usage: run.sh <workdir>
#
# Runs the full benchmark (78 goals: bench.ML over Main + bench2.ML over
# DTBench) against the component under test and aggregates the RESULT lines
# into <workdir>/results.tsv, results_datatypes.tsv and summaries.
#
# Prerequisites (see README.md):
#   - the bash server is running and wrote <workdir>/bash_server_addr.txt
#   - $NUNCHAKU_COMPONENT points at the component to test
#     (default: ../component next to this script -- only valid once the
#     packaging artifacts have been dropped into it)
#   - $ISABELLE names the isabelle executable (default: isabelle in PATH)
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
printf 'ISABELLE_HEAPS="%s"\nML_MAX_HEAP=50\n' "$WORK/heaps" > "$FAKE_ETC/settings"
printf '%s\n' "$COMP" > "$FAKE_ETC/components"

export USER_HOME="$WORK/fakehome" HOME="$WORK/fakehome"

ML64=$("$ISA" getenv -b ML_system_64)
[ "$ML64" = true ] || { echo "run.sh: ML_system_64=$ML64 (want true); aborting" >&2; exit 1; }
NUNHOME=$("$ISA" getenv -b NUNCHAKU_HOME)
[ "$NUNHOME" = "$COMP/x86_64-linux" ] || {
  echo "run.sh: NUNCHAKU_HOME=$NUNHOME does not point at $COMP/x86_64-linux" >&2; exit 1; }

ADDR=$(sed -n 1p "$WORK/bash_server_addr.txt")
PW=$(sed -n 2p "$WORK/bash_server_addr.txt")
[ -n "$ADDR" ] && [ -n "$PW" ] || {
  echo "run.sh: bad $WORK/bash_server_addr.txt (is the bash server running?)" >&2; exit 1; }

# run one ML file in a HOL ML_process (theory context Main), logging RESULT lines
run_ml () { # <ml-file> <logfile>
  "$ISA" ML_process -l HOL -C "$REGRESS" \
    -o bash_process_address="$ADDR" -o bash_process_password="$PW" \
    -e 'Context.setmp_generic_context (SOME (Context.Theory (Thy_Info.get_theory "Main"))) (fn () => ML_Context.eval_file ML_Compiler.flags (Path.explode "'"$1"'")) ()' \
    > "$2" 2>&1
}

run_arm () { # <ml-file> <prefix> <engine> <tier>
  echo "ARM_START $2 $3 $4 $(date +%T)"
  local rc=0
  BENCH_ENGINE=$3 BENCH_TIER=$4 run_ml "$REGRESS/$1" "$WORK/${2}_${3}_${4}.log" || rc=$?
  echo "ARM_END $2 $3 $4 rc=$rc results=$(grep -c '^RESULT' "$WORK/${2}_${3}_${4}.log" || true) $(date +%T)"
}

for tier in 1 5; do
  for engine in nitpick nunchaku nunchaku_smbc; do
    run_arm bench.ML  out  $engine $tier
    run_arm bench2.ML out2 $engine $tier
  done
done
echo "ALL_ARMS_DONE"

python3 "$REGRESS/aggregate.py"  "$WORK" > "$WORK/summary.txt"
python3 "$REGRESS/aggregate2.py" "$WORK" > "$WORK/summary_datatypes.txt"
echo "results: $WORK/results.tsv $WORK/results_datatypes.tsv"
