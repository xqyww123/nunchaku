#!/bin/bash
# W2 probe: build smbc in the same Isabelle switch, from a source tarball.
#
# smbc is NOT in the opam repository (checked: opam.ocaml.org/packages/smbc is
# 404), so it must be built from github.com/c-cube/smbc.  The certified
# version 0.4.1 cannot build on the Isabelle-pinned OCaml 4.14.1 at all
# (measured off-CI on linux with the same opam repo, so this is
# platform-independent): its native dependency era (containers < 2.0,
# transparent-`sequence`) is capped at ocaml < 4.07 by opam availability, and
# against any installable newer deps its code fails to type-check
# (Sequence.t/iter mismatch, `tip_parser` findlib name gone).  0.4.2 and 0.5
# fail the same way.  The nearest version that builds is 0.6 -- pristine, with
# containers 2.8.1 + msat 0.8.3 + tip-parser 0.6 + iter (0.6.1 builds too).
# This step therefore builds 0.6 and reports it; the on-CI question is only
# whether the same recipe works under the Cygwin toolchain.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

SMBC_VERSION=0.6
SMBC_URL="https://github.com/c-cube/smbc/archive/refs/tags/$SMBC_VERSION.tar.gz"
SMBC_SHA256=e43a295dcfdfa5d45209dda8d469086594ad3a497277602f924128b7f7074d62

SECONDS=0
# nunchaku (already built and staged) needed containers 3.x; smbc 0.6 needs
# the containers 2.x API, so this downgrades the switch's containers now.
# containers 2.x was archived out of the live opam repository ("no version
# 2.8.1", measured, round 7), so pin it straight from the upstream tarball.
"$ISA" env bash -c 'isabelle_opam pin add -y containers.2.8.1 \
  https://github.com/c-cube/ocaml-containers/archive/refs/tags/v2.8.1.tar.gz'
"$ISA" env bash -c \
  'isabelle_opam install -y msat.0.8.3 tip-parser.0.6 "iter>=1.0" base-bytes'
echo "PHASE smbc-deps OK in ${SECONDS}s"

mkdir -p smbc-src && cd smbc-src
curl -sSL --retry 3 -o smbc.tgz "$SMBC_URL"
echo "$SMBC_SHA256  smbc.tgz" | sha256sum -c
tar xzf smbc.tgz
cd "smbc-$SMBC_VERSION"

SECONDS=0
"$ISA" env bash -c 'cd "'"$WS"'/smbc-src/smbc-'"$SMBC_VERSION"'" && \
  isabelle_opam config exec --switch "$ISABELLE_OCAML_VERSION" -- dune build @install --profile=release'
echo "PHASE smbc-build OK in ${SECONDS}s"
echo "SMBC-BUILT: $SMBC_VERSION"

ls -la _build/default/src/
file _build/default/src/smbc.exe
mkdir -p "$WS/artifacts"
cp _build/default/src/smbc.exe "$WS/artifacts/smbc.exe"
"$WS/artifacts/smbc.exe" --version

"$ISA" env bash -c 'isabelle_opam list' | grep -Ei 'smbc|msat|tip-parser|containers|iter' || true
