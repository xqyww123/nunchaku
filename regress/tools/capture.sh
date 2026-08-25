#!/usr/bin/env bash
# Usage: capture.sh <workdir>
#
# Records the .nun problem Isabelle emits for every goal of the benchmark,
# without running any solver: the benchmark runs against a capture-only
# component (./capture-component) whose "nunchaku" saves its input and
# answers UNKNOWN.  Output:
#
#   <workdir>/capture-component/problems/pNNN.nun   one file per call
#   <workdir>/goalmap.txt                           pNNN <goal id>
#
# Feed the problems to ./dump_meta.sh to see which goals the
# spurious-model marking touches.
#
# Prerequisites, as for run.sh: $ISABELLE names the isabelle executable
# (default: isabelle in PATH) and $HOME/.isabelle/<id>/etc/preferences
# exists.  Takes a few minutes; runs no "isabelle build".
set -eu

TOOLS="$(cd "$(dirname "$0")" && pwd)"
REGRESS="$(cd "$TOOLS/.." && pwd)"
WORK=${1:?usage: capture.sh <workdir>}
ISA=${ISABELLE:-isabelle}
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

# the capture component is staged in the workdir, so the checked-in one stays
# clean and the problems land next to the copy that produced them
COMP="$WORK/capture-component"
rm -rf "$COMP"
cp -r "$TOOLS/capture-component" "$COMP"
sed -i "s/@NUNCHAKU_VERSION@/$(cat "$REGRESS/../VERSION")/" "$COMP/etc/settings"
mkdir -p "$COMP/problems"

. "$REGRESS/lib_bootstrap.sh"
isabelle_env
bash_server

run_ml () { # <ml-file> <logfile>
  BENCH_ENGINE=nunchaku_ship BENCH_TIER=5 \
  "$ISA" ML_process -l HOL -C "$REGRESS" \
    -o bash_process_address="$ADDR" -o bash_process_password="$PW" \
    -e 'Context.setmp_generic_context (SOME (Context.Theory (Thy_Info.get_theory "Main"))) (fn () => ML_Context.eval_file ML_Compiler.flags (Path.explode "'"$1"'")) ()' \
    > "$2" 2>&1 || true
}

run_ml "$REGRESS/bench.ML"  "$WORK/capture_bench.log"
run_ml "$REGRESS/bench2.ML" "$WORK/capture_bench2.log"

# one call per goal, in the order the RESULT lines were printed
awk -F'\t' '/^RESULT/ {print $3}' "$WORK/capture_bench.log" "$WORK/capture_bench2.log" \
  | awk '{printf "p%03d %s\n", NR-1, $1}' > "$WORK/goalmap.txt"

goals=$(wc -l < "$WORK/goalmap.txt")
probs=$(find "$COMP/problems" -name 'p*.nun' | wc -l)
echo "captured $probs problems for $goals goals -> $COMP/problems, $WORK/goalmap.txt"
[ "$probs" = "$goals" ] ||
  die "counts differ, so the goal map would be guesswork: a goal that timed out
        before calling the tool, or called it twice, shifts every later entry"

