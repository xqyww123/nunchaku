#!/bin/bash
# W2 probe follow-up: can the FULL dune runtest suite run under the Cygwin
# toolchain?  Must run BEFORE the smbc step: that step downgrades containers
# to 2.8.1, which would break the test build (nunchaku needs containers 3.x).
set -uo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

SECONDS=0
"$ISA" env bash -c 'isabelle_opam install -y qtest qcheck ounit' || {
  echo "TESTDEPS-FAILED after ${SECONDS}s"; exit 1; }
echo "PHASE test-deps OK in ${SECONDS}s"
"$ISA" env bash -c 'isabelle_opam list' | grep -Ei 'qtest|qcheck|ounit' || true

SECONDS=0
rc=0
"$ISA" env bash -c 'cd "'"$WS"'" && isabelle_opam config exec \
  --switch "$ISABELLE_OCAML_VERSION" -- dune runtest --profile=release' || rc=$?
echo "PHASE runtest done in ${SECONDS}s"
echo "RUNTEST-EXIT: $rc"
exit $rc
