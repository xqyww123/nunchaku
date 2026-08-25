#!/bin/bash
# win-64 release leg: the full `dune runtest` gate, under the Cygwin toolchain.
# Must run BEFORE the smbc step: that step downgrades containers
# to 2.8.1, which would break the test build (nunchaku needs containers 3.x).
set -uo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS" || exit 1

SECONDS=0
"$ISA" env bash -c 'isabelle_opam install -y qtest qcheck ounit' || {
  echo "TESTDEPS-FAILED after ${SECONDS}s"; exit 1; }
echo "PHASE test-deps OK in ${SECONDS}s"
"$ISA" env bash -c 'isabelle_opam list' | grep -Ei 'qtest|qcheck|ounit' || true

SECONDS=0
rc=0
# The inner single quotes are deliberate: $ISABELLE_OCAML_VERSION and the
# opam wrapper are resolved by the shell `isabelle env` starts, not by this one.
# shellcheck disable=SC2016
"$ISA" env bash -c 'cd "'"$WS"'" && isabelle_opam config exec \
  --switch "$ISABELLE_OCAML_VERSION" -- dune runtest --profile=release' || rc=$?
echo "PHASE runtest done in ${SECONDS}s"
echo "RUNTEST-EXIT: $rc"
exit $rc
