#!/bin/bash
# win-64 release leg: build nunchaku from the checked-out source with dune,
# inside the Isabelle opam switch.
set -euo pipefail
ISA="$(cygpath -u "$ISA_HOME_W")/bin/isabelle"
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

# The version comes from the VERSION file, not from git -- same reasoning as the
# unix legs (.github/scripts/release-build-unix.sh): `dune subst` needs
# `git describe`, which sees only lightweight tags in a CI checkout and would
# stamp a commit hash.  Without this line the win-64 binary would self-report
# whatever version the opam file happens to carry, and the release smoke's
# version assertion would be the thing that noticed.
sed -i "s/^version: .*/version: \"$(cat VERSION)\"/" nunchaku.opam
grep -q "^version: \"$(cat VERSION)\"$" nunchaku.opam \
  || { echo "::error::the version substitution did not take in nunchaku.opam"; exit 1; }

SECONDS=0
# The inner single quotes are deliberate: $ISABELLE_OCAML_VERSION and the
# opam wrapper are resolved by the shell `isabelle env` starts, not by this one.
# shellcheck disable=SC2016
"$ISA" env bash -c 'cd "'"$WS"'" && isabelle_opam config exec \
  --switch "$ISABELLE_OCAML_VERSION" -- dune build @install --profile=release'
echo "PHASE dune-build OK in ${SECONDS}s"

ls -la _build/default/src/main/
file _build/default/src/main/nunchaku.exe
mkdir -p artifacts
cp _build/default/src/main/nunchaku.exe artifacts/nunchaku.exe
# Stripped like every other leg, so the release ships one kind of artifact.
# Cygwin's strip comes from binutils, pulled in by the gcc-core package the
# workflow installs.  Unlike arm64 macOS there is no signature to invalidate.
strip artifacts/nunchaku.exe
ls -la artifacts/
