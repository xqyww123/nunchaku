#!/bin/bash
# W2 probe: build nunchaku from the checked-out source with dune, inside the
# Isabelle opam switch.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

SECONDS=0
"$ISA" env bash -c 'cd "'"$WS"'" && isabelle_opam config exec \
  --switch "$ISABELLE_OCAML_VERSION" -- dune build @install --profile=release'
echo "PHASE dune-build OK in ${SECONDS}s"

ls -la _build/default/src/main/
file _build/default/src/main/nunchaku.exe
mkdir -p artifacts
cp _build/default/src/main/nunchaku.exe artifacts/nunchaku.exe
