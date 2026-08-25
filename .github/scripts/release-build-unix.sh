#!/bin/bash
# Build the two binaries one unix release leg contributes: nunchaku, from this
# checkout, and smbc 0.6.1, from its upstream git tag.  Run under `opam exec --`
# so the switch setup-ocaml created is active.
#
# One script for all four unix legs; everything that differs between them is
# derived from $ISA_PLATFORM below, so there is no per-platform copy to keep in
# step.  win-64 is not a unix leg -- it builds through Isabelle's own bundled
# Cygwin toolchain, see .github/scripts/w2-*.sh.
#
# Inputs:
#   ISA_PLATFORM   Isabelle platform id of this leg (x86_64-linux, arm64-linux,
#                  x86_64-darwin, arm64-darwin)
# Outputs, in $PWD:
#   nunchaku-bin, smbc-bin   stripped, runnable, version-asserted
set -euo pipefail

: "${ISA_PLATFORM:?ISA_PLATFORM must name the Isabelle platform of this leg}"

# The certified smbc version.  Changing it is a re-certification event
# (regress/README.md section 2), and the assertion at the end of this script is
# its intended prompt.
SMBC_VERSION=0.6.1

die () { echo "::error::${0##*/}: $*"; exit 1; }

case "$ISA_PLATFORM" in
  *-linux)
    # ocaml-option-static alone leaves the final link dynamic (measured: a musl
    # PIE with interpreter /lib/ld-musl-x86_64.so.1).  OCAMLPARAM is what gets
    # -static into ocamlopt's C-linker invocation.  Exported, so the smbc build
    # further down inherits it and ships static too.
    export OCAMLPARAM="_,ccopt=-static"
    ;;
  *-darwin)
    # No -static here.  Apple ships no static libSystem, so on macOS a fully
    # static link cannot be produced at all; "redistributable" means "links
    # nothing outside /usr/lib", which release-verify-link.sh asserts.
    ;;
  *)
    die "unhandled ISA_PLATFORM '$ISA_PLATFORM'"
    ;;
esac

# ---------------------------------------------------------------------------
# nunchaku
# ---------------------------------------------------------------------------
# The version comes from the VERSION file, not from git: `dune subst` depends on
# `git describe`, which sees no annotated tag in a CI checkout (lightweight tags
# only) and would stamp a commit hash instead.  %{version:nunchaku} reads the
# opam file's version field (measured: it wins over dune-project's own
# (version) stanza).
#
# `sed -i.bak` plus a delete, not bare `sed -i`: BSD sed on the macOS legs
# requires an argument to -i, and bare -i there consumes the script as the
# suffix instead of failing.
sed -i.bak "s/^version: .*/version: \"$(cat VERSION)\"/" nunchaku.opam
rm -f nunchaku.opam.bak
grep -q "^version: \"$(cat VERSION)\"$" nunchaku.opam \
  || die "the version substitution did not take in nunchaku.opam"

dune build @install --profile=release
# The gate runs on this platform's own toolchain, not only on the linux build
# matrix: the three hermetic suites added in 0.5.3 fork, setsid, put children in
# their own process group and kill(-pid) them, and none of that is portable by
# assumption.
dune runtest --profile=release
cp _build/default/src/main/nunchaku.exe nunchaku-bin

# ---------------------------------------------------------------------------
# smbc 0.6.1 -- MUST come after `dune runtest` above
# ---------------------------------------------------------------------------
# This step force-downgrades containers to 2.8.1, because smbc needs the
# `containers.sexp` sublibrary that containers 3.x removed.  That contradicts
# nunchaku's own `containers >= 3.0` (nunchaku.opam) and breaks building the
# test runner, so it can only run once nunchaku is built and copied out of
# _build.  The Windows leg orders it the same way, for the same reason.
#
# 0.6.1 rather than the 0.4.1 the Isabelle distribution ships: 0.4.1 cannot be
# built on OCaml 4.14 at all -- its dependency era is capped at ocaml < 4.08,
# which predates arm64 macOS support entirely.  smbc is not in opam-repository
# (opam.ocaml.org/packages/smbc is 404), hence the pin straight from the
# upstream git tag; containers 2.x was archived out of the live repository,
# hence the archive repo.
opam repo add archive git+https://github.com/ocaml/opam-repository-archive
opam pin add -y -n "smbc.$SMBC_VERSION" \
  "git+https://github.com/c-cube/smbc.git#v$SMBC_VERSION"
opam install -y smbc "containers.2.8.1"
cp "$(opam var bin)/smbc" smbc-bin

# ---------------------------------------------------------------------------
# strip, re-sign, and prove both still run
# ---------------------------------------------------------------------------
finish () {
  strip "$1"
  case "$ISA_PLATFORM" in
    arm64-darwin)
      # strip invalidates the ad-hoc code signature that arm64 macOS requires.
      # Without re-signing, the kernel refuses to exec the binary at all, so
      # skipping this ships an artifact that cannot start on the target.
      codesign -f -s - "$1"
      ;;
  esac
  "$1" --version
}

finish nunchaku-bin
finish smbc-bin

# The shipped solver must be the certified one.  Redirect first and grep the
# file: piping a program into `grep -q` under `set -o pipefail` can fail the
# pipeline on SIGPIPE when grep exits early.
./smbc-bin --version > smbc-version.txt 2>&1
grep -q "$SMBC_VERSION" smbc-version.txt \
  || die "smbc reports '$(cat smbc-version.txt)', expected $SMBC_VERSION"

echo "built for $ISA_PLATFORM: nunchaku-bin + smbc-bin ($SMBC_VERSION)"
