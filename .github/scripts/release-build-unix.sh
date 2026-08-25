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
SRC_ROOT=${SRC_ROOT:-$PWD}
# shellcheck source=.github/scripts/solver-pins.sh
. "$SRC_ROOT/.github/scripts/solver-pins.sh"

# The certified smbc version and the commit its tag resolved to, both from
# component/solvers.pins -- the one file the win-64 leg and the packaging recipe
# read as well.  Changing either is a re-certification event
# (regress/README.md section 2), and the assertion at the end of this script is
# its intended prompt.
SMBC_VERSION=$(pin smbc-version)
SMBC_COMMIT=$(pin smbc-commit)

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
#
# `opam repo add` is guarded only because a bare `add` on an already-registered
# repo fails rather than shrugging, which under `set -e` would take the leg
# down.  It is NOT a warm-cache guard: setup-ocaml@v3 snapshots ~/.opam inside
# its own step (installer.ts:90, saveOpamCache() straight after installOcaml()),
# so a restored root is a bare compiler switch and never carries this job's own
# repo registrations or pins.
#
# Redirect first and grep the file, do not pipe into `grep -q`: a producer that
# keeps writing after grep exits on the first match dies of SIGPIPE, and under
# `pipefail` the guard then reports the repo MISSING when it is present -- which
# is the one way this guard can take the leg down.
opam repo list --short > opam-repos.txt
if ! grep -qx archive opam-repos.txt; then
  opam repo add archive git+https://github.com/ocaml/opam-repository-archive
fi
# The COMMIT, not the tag: a git tag is mutable, and smbc stamps its --version
# from smbc.opam's `version:` field, so a re-cut v0.6.1 would still report 0.6.1
# and pass every assertion below.  opam accepts a commit sha as the fragment.
# The pin NAME keeps the version, so the assertion at the end still reads.
opam pin add -y -n "smbc.$SMBC_VERSION" \
  "git+https://github.com/c-cube/smbc.git#$SMBC_COMMIT"
opam install -y smbc "containers.2.8.1"
cp "$(opam var bin)/smbc" smbc-bin

# ---------------------------------------------------------------------------
# strip, re-sign, and prove both still run
# ---------------------------------------------------------------------------
finish () {  # $1: ABSOLUTE path to a just-built binary
  local f=$1
  # The shape guard, not a comment: a name with no slash is resolved through
  # $PATH, and `.` is not on a GitHub runner's PATH.  `finish nunchaku-bin` --
  # what this function was called with before -- therefore died at
  # "nunchaku-bin: command not found", exit 127, on all four unix legs, on every
  # push, after the ~60-minute smbc build.  Rejecting a relative path makes the
  # slip unrepresentable instead of merely absent.
  case "$f" in
    /*) ;;
    *) die "finish needs an absolute path: $f" ;;
  esac
  strip "$f"
  case "$ISA_PLATFORM" in
    arm64-darwin)
      # strip invalidates the ad-hoc code signature that arm64 macOS requires.
      # Without re-signing, the kernel refuses to exec the binary at all, so
      # skipping this ships an artifact that cannot start on the target.
      codesign -f -s - "$f"
      ;;
  esac
  "$f" --version
}

finish "$PWD/nunchaku-bin"
finish "$PWD/smbc-bin"

# The shipped solver must be the certified one.  Redirect first and grep the
# file: piping a program into `grep -q` under `set -o pipefail` can fail the
# pipeline on SIGPIPE when grep exits early.
#
# -Fqx, not -q: the measured line is exactly `version: 0.6.1`, and a bare
# `grep -q 0.6.1` also matches `version: 0.6.11`.  The assertion is not
# decorative -- the smbc the Isabelle distribution ships reports
# `version: (commit 123f9a4c...)`, a real spelling with no version number in it.
./smbc-bin --version > smbc-version.txt 2>&1
grep -Fqx "version: $SMBC_VERSION" smbc-version.txt \
  || die "smbc reports '$(cat smbc-version.txt)', expected version: $SMBC_VERSION"

echo "built for $ISA_PLATFORM: nunchaku-bin + smbc-bin ($SMBC_VERSION)"
