#!/bin/bash
# The CLI smoke every release leg runs -- the four unix legs directly, the
# win-64 leg under Isabelle's own bundled Cygwin bash (see w2-smoke.sh).
#
# It smokes THE SHIPPING CONFIGURATION, not the bare binary.  It assembles
# exactly the component layout the conda package will have -- the wrapper, the
# binary, solvers/cvc5, solvers/smbc -- and drives the wrapper.  That matters
# most on win-64: the wrapper exports NUNCHAKU_CVC5 and NUNCHAKU_SMBC as
# extension-less paths, and only Cygwin's own .exe-appending makes them satisfy
# `test -f` and `test -x` in external_program_available (src/core/Utils.ml).
# Driving the bare binary with explicit .exe paths -- what the platform probe
# did -- would not have exercised that at all.
#
# Inputs (paths absolute, in THIS shell's namespace):
#   ISA_PLATFORM   Isabelle platform id of this leg
#   SRC_ROOT       the repository checkout (VERSION, component/, regress/)
#   NUNCHAKU_SRC   the freshly built nunchaku binary
#   SMBC_SRC       the freshly built smbc binary
#   CVC5_SRC       the pinned cvc5 binary
#   EXE            executable suffix: "" on unix, ".exe" under Cygwin
set -euo pipefail

: "${ISA_PLATFORM:?}" "${SRC_ROOT:?}" "${NUNCHAKU_SRC:?}" "${SMBC_SRC:?}" "${CVC5_SRC:?}"
EXE=${EXE:-}

die () { echo "::error::${0##*/}: $*"; exit 1; }

# sha256_of lives in solver-pins.sh so the digest tool has one definition
# across the scripts that need it (release-fetch-cvc5.sh is the other).
# shellcheck source=.github/scripts/solver-pins.sh
. "$SRC_ROOT/.github/scripts/solver-pins.sh"

version=$(cat "$SRC_ROOT/VERSION")
gold="$SRC_ROOT/regress/gold.nun"
[ -f "$gold" ] || die "$gold not found"

# ---------------------------------------------------------------------------
# assemble the component exactly as the package will lay it out
# ---------------------------------------------------------------------------
stage="$PWD/component-stage"
rm -rf "$stage"
plat_dir="$stage/$ISA_PLATFORM"
mkdir -p "$plat_dir/solvers"
install -m 755 "$SRC_ROOT/component/nunchaku" "$plat_dir/nunchaku"
install -m 755 "$NUNCHAKU_SRC" "$plat_dir/nunchaku-bin$EXE"
install -m 755 "$SMBC_SRC"     "$plat_dir/solvers/smbc$EXE"
install -m 755 "$CVC5_SRC"     "$plat_dir/solvers/cvc5$EXE"
echo "=== staged component ==="
ls -lR "$stage"

nun="$plat_dir/nunchaku"

# ---------------------------------------------------------------------------
# 1. the binary self-reports the release version
# ---------------------------------------------------------------------------
# The VERSION file is the single source: the tag, the opam version field, this
# string and the conda package version all come from it.  Redirect to a file
# and grep the file -- piping a program into `grep -q` under `set -o pipefail`
# can fail the pipeline on SIGPIPE when grep exits on the first match.
"$plat_dir/nunchaku-bin$EXE" --version > version.txt
cat version.txt
grep -q " $version " version.txt \
  || die "the binary does not self-report version $version: $(cat version.txt)"

# ---------------------------------------------------------------------------
# 2. the wrapper runs from where it will live
# ---------------------------------------------------------------------------
"$nun" --help > /dev/null || die "the wrapper cannot run --help"

run_gold () {  # <tag> <solver args...>
  local tag=$1
  shift
  local rc=0
  echo
  echo "=== gold.nun, $* ==="
  "$nun" --skolems-in-model --no-color --no-specialize "$@" --timeout 30 \
    "$gold" > "smoke-$tag.out" 2> "smoke-$tag.err" || rc=$?
  echo "exit=$rc"
  echo "--- stdout"; cat "smoke-$tag.out"
  echo "--- stderr"; cat "smoke-$tag.err"
  [ "$rc" -eq 0 ] || die "the $tag run exited $rc"
}

# ---------------------------------------------------------------------------
# 3. the exact flag table the Isabelle frontend sends
# ---------------------------------------------------------------------------
run_gold frontend --solvers "cvc5,kodkod,paradox,smbc" \
  --kodkod-min-bound 4 --kodkod-max-bound 8 --kodkod-bound-increment 4
grep -q '^SAT' smoke-frontend.out || die "the frontend run did not answer SAT"
grep -q '{backend:' smoke-frontend.out || die "the frontend run lost the {backend:...} line"

# BOTH bundled solvers must really be wired up through the wrapper.  nunchaku
# emits one aggregated stderr line naming every requested-but-unavailable
# solver (warn_unavailable_requested_ in src/main/nunchaku.ml); the component
# bundles cvc5 and smbc and bundles neither kodkod nor paradox, so that line
# must name exactly those two.  Measured on 0.5.3: with smbc present the line
# is "[Warning solver not available: kodkod, paradox]", and with smbc absent it
# is "[... kodkod, paradox, smbc]" -- which is precisely the defect this
# assertion exists to catch, and the reason it names the solvers instead of
# just checking that the run answered.
#
# `case` on a variable, not a pipeline: `grep -q` closing the pipe early can
# make an upstream `tr` die of SIGPIPE and fail the pipeline under pipefail.
warn=$(tr -s '[:space:]' ' ' < smoke-frontend.err)
case "$warn" in
  *"solver not available: kodkod, paradox]"*) ;;
  *) die "expected the unavailable-solver line to name exactly kodkod and paradox; stderr was: $warn" ;;
esac

# ---------------------------------------------------------------------------
# 4. cvc5 alone
# ---------------------------------------------------------------------------
run_gold cvc5 --solvers cvc5
grep -q '^SAT' smoke-cvc5.out || die "the cvc5 run did not answer SAT"
grep -q '{backend:cvc5' smoke-cvc5.out || die "the cvc5 run was not answered by cvc5"

# ---------------------------------------------------------------------------
# 5. smbc alone -- the arm 0.5.3 newly bundles, and it ships un-smoked otherwise
# ---------------------------------------------------------------------------
run_gold smbc --solvers smbc
# ^SAT, unconditionally and on every platform, because it is the ONLY thing that
# separates a working bundled smbc from a dead one.  Measured 2026-08-25 with
# the real 0.5.3 binary and the real cvc5 1.3.4, over four broken payloads: an
# smbc that exits 1, 200 executable bytes the kernel cannot exec, one that
# prints unparseable output, and one that hangs -- all four answered with a
# UNKNOWN/TIMEOUT line, all four left stderr EMPTY, and all four passed the
# previous form of this assertion.
#
# In particular a present-but-broken smbc does NOT print the unavailable-solver
# line: availability is `test -f && test -x` (src/core/Utils.ml), which 755
# garbage satisfies, and nothing execs until the backend runs.  So the stderr
# check that used to stand here could not fire and has been deleted.
#
# The verdict IS pinned, on all five: gold.nun under --solvers smbc answers SAT
# with {backend:smbc -- x86_64-cygwin included (platform-probe run w2-r12.log:
# `== gold.nun with --solvers smbc ==` -> exit=0 -> SAT -> {backend:smbc,
# time:0.1s}), so no platform carve-out is warranted.
#
# BACKEND_ERROR is the second limb because it is what the exit-1, the
# Exec-format-error and the unparseable-output payloads produce; the hang
# produces (TIMEOUT {backend:scheduler}) with no {backend:smbc at all, which the
# first limb catches.  `! grep ... || die`, not `grep ... && die`: the latter
# becomes the script's exit status if it ever ends up last.
grep -q '^SAT' smoke-smbc.out \
  || die "the smbc run did not answer SAT: $(cat smoke-smbc.out)"
! grep -q 'BACKEND_ERROR' smoke-smbc.out \
  || die "the bundled smbc failed: $(cat smoke-smbc.out)"

# ---------------------------------------------------------------------------
# 6. the version record this leg hands to the packaging repository
# ---------------------------------------------------------------------------
# The two --version lines, captured HERE because this is the one script that
# runs on all five legs under the runtime the binaries actually need -- on
# x86_64-cygwin that is Isabelle's own bundled Cygwin, and no other step in the
# pipeline can execute those two binaries at all.  release-attach.sh publishes
# this file with the binaries, and isabelle-packaging-ci asserts the nunchaku
# line's version and 40-hex commit fields against the release tag before it
# packages anything.  Without it, the packaging side's only content check on the
# two win-64 binaries is that their first two bytes are "MZ".
#
# Redirect to a file and read the file, never `prog | head -1`: this script's
# other captures do the same, because a program that keeps writing after head
# exits dies of SIGPIPE and fails the pipeline under `set -o pipefail`.
"$plat_dir/solvers/smbc$EXE" --version > smbc-smoke-version.txt 2>&1
nun_line=$(head -1 version.txt)
smbc_line=$(head -1 smbc-smoke-version.txt)

# The record is ASSERTED where it is written, not only where it is read.
# src/main/dune builds GitVersion.ml with
# `(git rev-parse HEAD | tr -d '\n') || echo -n unknown`, so a build whose git
# call fails -- on win-64 that build runs inside Isabelle's Cygwin over a
# workspace checked out by Windows git, where a safe.directory complaint is
# enough -- stamps the literal `unknown`.  The version check at step 1 above is
# `grep -q " $version "`, which `nunchaku 0.5.3 unknown` satisfies (measured
# 2026-08-25).  Without the check below, such a leg goes green, attaches its
# record, and is caught only by isabelle-packaging-ci -- one repository and one
# publish gate later.  The prefix `nunchaku <version> ` is matched literally and
# the whole remainder must be forty lowercase hex characters -- which is also
# what rules out a fourth field, since a space is not hex.  That remainder is
# the commit the packaging side compares against the tag.
# `case`, not `grep -E`: no subprocess, and the character class is enumerated
# rather than written as a range, so no collation order can widen it.
prefix="nunchaku $version "
case "$nun_line" in
  "$prefix"*) commit=${nun_line#"$prefix"} ;;
  *) die "the version record must read 'nunchaku $version <40-hex commit>'; the binary said '$nun_line'" ;;
esac
case "$commit" in
  *[!0123456789abcdef]*) hex=no ;;
  *)                     hex=yes ;;
esac
# The length is in the message because the character that most often breaks
# this is invisible: a CR from a CRLF checkout makes the field print exactly
# like a good sha, and only "41 characters" says what is wrong.
if [ "$hex" != yes ] || [ "${#commit}" -ne 40 ]; then
  die "the version record's commit field is not 40 lowercase hex; it is ${#commit} characters: '$commit'"
fi
# Nothing is asserted about the smbc line here: release-build-unix.sh:154-156 and
# w2-smbc.sh:89-92 already require these exact bytes to answer
# `version: <pinned smbc version>` on their own leg, and re-stating it would be
# a second place for the same rule to live.
{
  printf 'nunchaku-bin --version: %s\n' "$nun_line"
  printf 'smbc-bin --version: %s\n' "$smbc_line"
} > "$PWD/versions-$ISA_PLATFORM.txt"
echo "=== versions-$ISA_PLATFORM.txt ==="
cat "$PWD/versions-$ISA_PLATFORM.txt"

# Digest the two binaries HERE, on the leg that built them, and ship the
# sidecars inside this leg's artifact.  release-attach.sh then verifies them
# instead of recomputing, so the digest that reaches the release was taken
# before the artifact round trip rather than after it.  On x86_64-cygwin that
# is the only end-to-end check on the binary's bytes at all: no job on either
# side ever executes a Cygwin binary, so the packaging side's content check is
# otherwise the two bytes `MZ`.
# Digest the script's own INPUTS, not a pair of bare names in $PWD: on the
# win-64 leg the binaries are $WS/artifacts/*.exe and the bare names do not
# exist until a step that runs after this one, so hashing by name would fail
# that leg -- measured by running this block in a reconstructed win-64
# workspace, not on a runner; no leg of this workflow has run yet.  Hashing the
# inputs also makes the digested file the same file the smoke just drove, which
# hashing a copy would not guarantee.
# The sidecar records the RELEASED stem, because that is the name
# release-attach.sh verifies it under.
digest () {  # <source path> <released stem>
  [ -s "$1" ] || die "$1 is missing -- the leg cannot digest what it built"
  printf '%s  %s\n' "$(sha256_of "$1" | cut -d' ' -f1)" "$2" > "$PWD/$2.sha256"
  cat "$PWD/$2.sha256"
}
digest "$NUNCHAKU_SRC" nunchaku-bin
digest "$SMBC_SRC" smbc-bin

echo
echo "smoke OK for $ISA_PLATFORM"
