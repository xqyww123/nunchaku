#!/bin/bash
# win-64 release leg: build smbc in the same Isabelle switch that built
# nunchaku, from the upstream git tag.
#
# smbc is NOT in the opam repository (opam.ocaml.org/packages/smbc is 404), so
# it must come from github.com/c-cube/smbc.  The version the Isabelle
# distribution ships, 0.4.1, cannot build on the Isabelle-pinned OCaml 4.14.1
# at all (measured off-CI on linux with the same opam repo, so this is
# platform-independent): its native dependency era -- containers < 2.0, the
# transparent `sequence` library -- is capped at ocaml < 4.07 by opam
# availability, and against any installable newer deps its code fails to
# type-check (Sequence.t/iter mismatch, the `tip_parser` findlib name gone).
# 0.4.2 and 0.5 fail the same way.  0.6.1 is the version the release certifies
# (regress/README.md section 2), and it is the same commit the four unix legs
# pin -- both read component/solvers.pins -- so all five ship the same solver.
#
# MUST run after w2-runtest.sh: the containers downgrade below breaks building
# nunchaku's test runner.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

SRC_ROOT="$WS"
# shellcheck source=.github/scripts/solver-pins.sh
. "$WS/.github/scripts/solver-pins.sh"
SMBC_VERSION=$(pin smbc-version)
SMBC_COMMIT=$(pin smbc-commit)

SECONDS=0
# nunchaku (already built and staged) needed containers 3.x; smbc needs the
# containers 2.x API -- the `containers.sexp` sublibrary 3.x removed -- so this
# downgrades the switch's containers now.  containers 2.x was archived out of
# the live opam repository ("no version 2.8.1", measured), hence the pin
# straight from the upstream tarball rather than an `opam install`.
"$ISA" env bash -c 'isabelle_opam pin add -y containers.2.8.1 \
  https://github.com/c-cube/ocaml-containers/archive/refs/tags/v2.8.1.tar.gz'
# smbc 0.6.1's own depends: dune, base-bytes, containers >= 2.0, iter >= 1.0,
# msat >= 0.8 < 0.9, tip-parser >= 0.6 < 0.7.  Installed explicitly because
# this switch resolves against the live repository only; the unix legs instead
# add the opam archive repo and let `opam install smbc` resolve them.
"$ISA" env bash -c \
  'isabelle_opam install -y msat.0.8.3 tip-parser.0.6 "iter>=1.0" base-bytes'
echo "PHASE smbc-deps OK in ${SECONDS}s"

# Build OUTSIDE the nunchaku checkout: dune walks up to the enclosing workspace
# root, so a source tree under $WS would land its artifacts in nunchaku's
# _build instead of its own (measured).
BUILDDIR="$HOME/smbc-build"
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
cd "$BUILDDIR"
# A shallow clone of the tag, then the COMMIT asserted: the four unix legs hand
# opam the commit directly, and this is the same pin from the other side.  A git
# tag is mutable, and smbc stamps `%{version:smbc}` from smbc.opam's `version:`
# field, so a re-cut v0.6.1 would still report 0.6.1 and pass every other
# assertion in this script -- this line is the only thing that pins the bytes.
git clone --depth 1 --branch "v$SMBC_VERSION" https://github.com/c-cube/smbc.git smbc-src
cd smbc-src
head=$(git rev-parse HEAD)
[ "$head" = "$SMBC_COMMIT" ] \
  || { echo "::error::smbc tag v$SMBC_VERSION moved: it is now $head, and component/solvers.pins pins $SMBC_COMMIT"; exit 1; }
# dune stamps `%{version:smbc}` into the binary from this file, so the version
# the release asserts is the tag's own.
grep -Fqx "version: \"$SMBC_VERSION\"" smbc.opam \
  || { echo "::error::smbc.opam at tag v$SMBC_VERSION does not declare version $SMBC_VERSION"; exit 1; }

SECONDS=0
# The inner single quotes are deliberate: $ISABELLE_OCAML_VERSION and the
# opam wrapper are resolved by the shell `isabelle env` starts, not by this one.
# shellcheck disable=SC2016
"$ISA" env bash -c 'cd "'"$BUILDDIR"'/smbc-src" && \
  isabelle_opam config exec --switch "$ISABELLE_OCAML_VERSION" -- dune build @install --profile=release'
echo "PHASE smbc-build OK in ${SECONDS}s"

ls -la _build/default/src/
file _build/default/src/smbc.exe
mkdir -p "$WS/artifacts"
cp _build/default/src/smbc.exe "$WS/artifacts/smbc.exe"
# Stripped like every other leg (see w2-build.sh).
strip "$WS/artifacts/smbc.exe"

# The shipped solver must be the certified one.  Redirect first and grep the
# file: piping a program into `grep -q` under `set -o pipefail` can fail the
# pipeline on SIGPIPE when grep exits on the first match.
#
# -Fqx, not -q: the measured line is exactly `version: 0.6.1`, and a bare
# `grep -q 0.6.1` also matches `version: 0.6.11`.
"$WS/artifacts/smbc.exe" --version > "$WS/smbc-version.txt" 2>&1
cat "$WS/smbc-version.txt"
grep -Fqx "version: $SMBC_VERSION" "$WS/smbc-version.txt" \
  || { echo "::error::smbc reports '$(cat "$WS/smbc-version.txt")', expected version: $SMBC_VERSION"; exit 1; }

"$ISA" env bash -c 'isabelle_opam list' | grep -Ei 'msat|tip-parser|containers|iter' || true
