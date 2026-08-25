#!/bin/bash
# Link-footprint evidence for release binaries -- one dispatch covering all five
# platforms.
#
#   release-verify-link.sh <isabelle-platform> <binary>...
#
# Each branch asserts the property that makes the artifact redistributable on
# that platform, and each prints the full evidence first so a failure can be
# read without re-running anything.
set -euo pipefail

plat=${1:?Isabelle platform id}
shift
[ "$#" -gt 0 ] || { echo "::error::${0##*/}: no binaries given"; exit 1; }

die () { echo "::error::${0##*/}: $*"; exit 1; }

for f in "$@"; do
  echo "===== $f ====="
  case "$plat" in
    *-linux)
      file "$f" || true
      readelf -l "$f" | head -20
      # INTERP is an ELF program-header NAME, so this test is locale- and
      # wording-independent, unlike parsing ldd's message.  A musl-static
      # build has no program interpreter at all; anything with one would need
      # a loader we do not ship.
      readelf -l "$f" > readelf.out
      ! grep -q INTERP readelf.out \
        || die "$f is dynamically linked -- it has a PT_INTERP segment"
      ;;
    *-darwin)
      otool -L "$f"
      # macOS has no static libSystem, so "static enough to redistribute" means
      # "links nothing outside /usr/lib".  otool's first output line is the
      # file's own name, hence tail -n +2.
      rest=$(otool -L "$f" | tail -n +2 | grep -v '/usr/lib/' || true)
      [ -z "$rest" ] || die "$f links outside /usr/lib:
$rest"
      ;;
    *-cygwin)
      cygcheck "$f" > cygcheck.out 2>&1 || die "cygcheck failed on $f"
      cat cygcheck.out
      # The component is driven from Isabelle's own bundled Cygwin, and the
      # wrapper hands the solvers extension-less paths that only Cygwin's
      # .exe-appending resolves.  A binary that did NOT link cygwin1.dll would
      # be a native build with different path semantics -- it would start, and
      # then fail to find its solvers.  So assert the Cygwin ABI positively.
      grep -qi 'cygwin1\.dll' cygcheck.out \
        || die "$f does not link cygwin1.dll -- not a Cygwin-ABI binary"
      # Deliberately NOT asserted: that no other DLL appears.  The full list is
      # printed above; what it may legitimately contain has never been measured
      # here, and an assertion nobody has measured is a release blocker waiting
      # to happen.
      ;;
    *)
      die "unhandled platform '$plat'"
      ;;
  esac
done
