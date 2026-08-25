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
# The VERDICT is deliberately not pinned: the two platform probes measured
# different ones for this input (SAT on macOS, "any definite answer" on
# Windows), and which one gold.nun gets from smbc is not what the release
# depends on.  What it depends on is that the bundled smbc is FOUND and RUNS,
# and the absence of the unavailable-solver line says exactly that -- a missing
# or unexecutable smbc prints it and would otherwise slip through as a bland
# UNKNOWN answered by the scheduler.
grep -Eq '^(SAT|UNSAT|UNKNOWN|TIMEOUT)' smoke-smbc.out \
  || die "the smbc run produced no answer line"
smbc_warn=$(tr -s '[:space:]' ' ' < smoke-smbc.err)
case "$smbc_warn" in
  *"solver not available"*) die "the bundled smbc was not available to the wrapper: $smbc_warn" ;;
esac

echo
echo "smoke OK for $ISA_PLATFORM"
