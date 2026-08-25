#!/bin/bash
# Link-footprint and architecture evidence for release binaries -- one dispatch
# covering all five platforms.
#
#   release-verify-link.sh <isabelle-platform> <binary>...
#
# Each branch asserts the two properties that make the artifact publishable
# under that platform id: it is redistributable there (no loader we do not
# ship), and it is FOR that architecture.  The second half exists because
# nothing else in the pipeline binds a leg's bytes to the name it is published
# under -- a moved runner label or a matrix typo would otherwise produce a green
# leg whose binaries run natively on the builder, answer SAT, pass every link
# check from both sides of the handover, and reach a user under the wrong
# platform id.
#
# Each branch prints the full evidence first so a failure can be read without
# re-running anything.
set -euo pipefail

# LC_ALL=C, once, for the whole script.  readelf's output is TRANSLATED --
# measured 2026-08-25 under zh_CN.UTF-8, where "Machine:" prints as
# "系统架构:" and every English-text assertion below silently stops matching.
# This is the same class the INTERP comment further down is about: assert on
# names and structure, never on a tool's prose, and where prose is unavoidable
# pin the locale that produces it.
export LC_ALL=C

plat=${1:?Isabelle platform id}
shift
[ "$#" -gt 0 ] || { echo "::error::${0##*/}: no binaries given"; exit 1; }

die () { echo "::error::${0##*/}: $*"; exit 1; }

# A little-endian integer field read straight out of the file, for the one
# format with no wording-free tool on its own platform.  Bytes are composed
# explicitly rather than with `od -tu2`, whose byte order is the HOST's.
le_field () {  # <file> <byte-offset> <width in {2,4}>
  local b
  b=$(od -An -tx1 -j "$2" -N "$3" -- "$1" | tr -d ' \n')
  if [ "$3" -eq 2 ]; then
    printf '%d\n' "0x${b:2:2}${b:0:2}"
  else
    printf '%d\n' "0x${b:6:2}${b:4:2}${b:2:2}${b:0:2}"
  fi
}

for f in "$@"; do
  echo "===== $f ====="
  case "$plat" in
    *-linux)
      file "$f" || true
      # One invocation, then read the file: `readelf -l "$f" | head -20` under
      # `pipefail` fails the pipeline when head exits first and readelf keeps
      # writing.
      readelf -l "$f" > readelf-l.out
      head -20 readelf-l.out
      readelf -h "$f" > readelf-h.out
      cat readelf-h.out
      # POSITIVE first.  An absence assertion cannot fail on garbage: measured
      # 2026-08-25, the first 100 bytes of a real static ELF give `readelf -l`
      # exit 0 with no program headers at all, hence no INTERP, hence "PASS".
      # A file that is an ELF executable with at least one LOAD segment cannot
      # be that.
      grep -Eq '^ *Type: +(EXEC|DYN)' readelf-h.out \
        || die "$f is not an ELF executable"
      grep -q '^ *LOAD' readelf-l.out \
        || die "$f has no PT_LOAD segment -- truncated or not an ELF image"
      # INTERP is an ELF program-header NAME, so this test is locale- and
      # wording-independent, unlike parsing ldd's message.  A musl-static
      # build has no program interpreter at all; anything with one would need
      # a loader we do not ship.
      ! grep -q INTERP readelf-l.out \
        || die "$f is dynamically linked -- it has a PT_INTERP segment"
      case "${plat%%-*}" in
        arm64) want="Machine: *AArch64" ;;
        *)     want="Machine: *Advanced Micro Devices X86-64" ;;
      esac
      grep -Eq "^ *$want" readelf-h.out \
        || die "$f is not the $plat architecture: $(grep Machine readelf-h.out)"
      ;;
    *-darwin)
      otool -L "$f"
      # macOS has no static libSystem, so "static enough to redistribute" means
      # "links nothing outside /usr/lib".  otool's first output line is the
      # file's own name, hence tail -n +2.
      rest=$(otool -L "$f" | tail -n +2 | grep -v '/usr/lib/' || true)
      [ -z "$rest" ] || die "$f links outside /usr/lib:
$rest"
      # lipo prints bare architecture names, not prose, so it needs no wording
      # allowance.  A single-arch binary prints exactly one.
      case "${plat%%-*}" in
        arm64) want=arm64 ;;
        *)     want=x86_64 ;;
      esac
      got=$(lipo -archs "$f")
      echo "architectures: $got"
      [ "$got" = "$want" ] || die "$f is '$got', not $want as $plat claims"
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
      #
      # The architecture comes from the PE header's own bytes rather than from
      # `file`, whose exact Cygwin wording has never been measured here either:
      # e_lfanew is a 4-byte LE offset at 0x3c, the 4 bytes there are "PE\0\0",
      # and the 2 bytes after that are COFF Machine -- 0x8664 for x86-64.
      [ "$(le_field "$f" 0 2)" -eq 23117 ] || die "$f is not a PE image (no MZ)"
      pe=$(le_field "$f" 60 4)
      sig=$(od -An -c -j "$pe" -N 4 -- "$f" | tr -d ' \n')
      [ "$sig" = 'PE\0\0' ] || die "$f has no PE signature at e_lfanew=$pe"
      mach=$(le_field "$f" "$((pe + 4))" 2)
      echo "PE machine: $mach (34404 = x86-64)"
      [ "$mach" -eq 34404 ] || die "$f is PE machine $mach, not x86-64 as $plat claims"
      ;;
    *)
      die "unhandled platform '$plat'"
      ;;
  esac
done
