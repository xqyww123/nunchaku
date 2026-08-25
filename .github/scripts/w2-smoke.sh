#!/bin/bash
# win-64 release leg: run the shared release smoke and the shared link check
# under Isabelle's own bundled Cygwin.
#
# This is a thin adapter, not a second smoke.  Its only job is to translate the
# leg's Windows paths into the POSIX namespace the Cygwin shell lives in and
# hand them to .github/scripts/release-smoke.sh, so win-64 asserts exactly what
# the four unix legs assert -- same staged component layout, same flag table,
# same solver-availability assertions.
set -euo pipefail
WS="$(cygpath -u "$GITHUB_WORKSPACE")"
cd "$WS"

export ISA_PLATFORM=x86_64-cygwin
export SRC_ROOT="$WS"
export NUNCHAKU_SRC="$WS/artifacts/nunchaku.exe"
export SMBC_SRC="$WS/artifacts/smbc.exe"
export CVC5_SRC="$WS/solvers/cvc5.exe"
# The staged component names the binaries WITHOUT this suffix where the wrapper
# reads them and WITH it on disk -- which is the point of smoking here at all:
# NUNCHAKU_CVC5/NUNCHAKU_SMBC are extension-less and only Cygwin's own
# .exe-appending makes them resolve.
export EXE=.exe

bash "$WS/.github/scripts/release-smoke.sh"
bash "$WS/.github/scripts/release-verify-link.sh" x86_64-cygwin \
  "$NUNCHAKU_SRC" "$SMBC_SRC"

echo "== binary sizes =="
ls -la artifacts/ solvers/
