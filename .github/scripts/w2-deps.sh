#!/bin/bash
# W2 probe: install nunchaku's build dependencies into the Isabelle switch.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

SECONDS=0
if ! "$ISA" env bash -c \
    'cd "'"$WS"'" && isabelle_opam install -y --deps-only ./nunchaku.opam'; then
  echo "deps-only install from ./nunchaku.opam failed; falling back to explicit list"
  "$ISA" env bash -c \
    'isabelle_opam install -y dune "containers>=3.0" "containers-data>=3.0" menhir "iter>=1.0" num'
fi
echo "PHASE deps OK in ${SECONDS}s"
"$ISA" env bash -c 'isabelle_opam list' | grep -Ei 'dune|containers|menhir|iter|num|ocaml ' || true
