#!/usr/bin/env bash
# Usage: dump_meta.sh <problem.nun>...
#
# Prints, for each problem and each encoding branch, the two metadata flags
# that decide whether the answer may lie:
#
#   <problem> <branch> sat_means_unknown=<bool> unsat_means_unknown=<bool>
#
# This is the cheap way to answer "which goals does the marking touch?".
# It runs no solver: each backend is replaced by a stub that exits at once,
# because the flags are computed by the encoding pipeline, before any
# backend is called.  A problem gets a different encoding per branch of the
# pipeline, and the branches do not always agree, so all three are printed:
# "cvc5" (shared with cvc4), "kodkod" (shared with paradox) and "smbc".
#
#   $NUNCHAKU names the binary (default: the dune build tree).
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NUN=${NUNCHAKU:-$REPO/_build/default/src/main/nunchaku.exe}
[ -x "$NUN" ] || { echo "dump_meta.sh: no executable $NUN" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: dump_meta.sh <problem.nun>..." >&2; exit 1; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$STUB/solver"
chmod +x "$STUB/solver"

for pb in "$@"; do
  for branch in cvc5 kodkod smbc; do
    case $branch in
      cvc5) env_var=NUNCHAKU_CVC5 ;;
      kodkod) env_var=NUNCHAKU_KODKODI ;;
      smbc) env_var=NUNCHAKU_SMBC ;;
    esac
    # the run itself is expected to fail: the stub answers nothing
    flags=$(env "$env_var=$STUB/solver" "$NUN" --debug.mark_spurious 1 \
              --solvers "$branch" --timeout 1 "$pb" 2>&1 |
            grep -o 'sat_means_unknown=[a-z]*, unsat_means_unknown=[a-z]*' |
            head -1)
    printf '%s\t%s\t%s\n' "$pb" "$branch" "${flags:-NO METADATA (did the problem parse?)}"
  done
done
