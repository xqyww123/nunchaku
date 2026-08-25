#!/bin/bash
# Read one record out of component/solvers.pins.  SOURCED, never executed --
# every release script that needs a solver pin gets it from here, so the pins
# have exactly one parser as well as exactly one definition.
#
#   . "$SRC_ROOT/.github/scripts/solver-pins.sh"
#   ver=$(pin cvc5-version)                    # -> 1.3.4
#   row=$(pin cvc5 x86_64-linux)               # ASSIGN FIRST, then split:
#   read -r asset sha <<< "$row"
#   plats=$(pin_platforms)                     # -> the five Isabelle platform ids
#
# ASSIGN FIRST is not a style preference.  Both functions report a broken or
# half-edited pins file by printing `::error::` and returning non-zero, and that
# status only reaches `set -e` if a plain assignment takes it.  `read -r a b <<<
# "$(pin ...)"` takes READ's status and `echo "X=$(pin ...)"` takes ECHO's, so
# either one turns a loud failure into an empty value; measured 2026-08-25, the
# win-64 pins step written that way exited 0 after writing `CVC5_VERSION=` into
# $GITHUB_ENV and died 250 minutes later on a cvc5 URL 404.  The same applies to
# `while read ... < <(pin_platforms)`: a process substitution's status is never
# examined, so assign the list and iterate over the variable.
#
# Inputs:
#   SRC_ROOT   the repository checkout (defaults to $PWD), or set PINS_FILE
#              directly to point at a specific file (the negative-control hook).

PINS_FILE=${PINS_FILE:-${SRC_ROOT:-$PWD}/component/solvers.pins}

pin () {  # <selector word>...  -- prints the record's remaining fields
  local sel="$*" out
  # Exactly one match, or fail: a missing record and a half-applied edit that
  # left two are both errors, and both are silent if the first match wins.
  out=$(PIN_SEL="$sel" awk '
    BEGIN { n = split(ENVIRON["PIN_SEL"], sel, " ") }
    /^[[:space:]]*#/ || NF == 0 { next }
    {
      for (i = 1; i <= n; i++) if ($i != sel[i]) next
      s = ""
      for (i = n + 1; i <= NF; i++) s = s (i > n + 1 ? " " : "") $i
      print s
      hits++
    }
    END { exit(hits == 1 ? 0 : 1) }
  ' "$PINS_FILE") || {
    echo "::error::solver-pins.sh: $PINS_FILE has no unique record for '$sel'" >&2
    return 1
  }
  printf '%s\n' "$out"
}

pin_platforms () {  # the Isabelle platform ids a release covers, one per line
  local out
  # An unreadable pins file and a pins file with no cvc5 records are the same
  # kind of accident, and both are silent unless this returns non-zero: the
  # release contract, the download list and the win-64 export are all built by
  # iterating this, and an empty list agrees with every diff drawn against it.
  out=$(awk '$1 == "cvc5" { print $2 }' "$PINS_FILE") || {
    echo "::error::solver-pins.sh: cannot read $PINS_FILE" >&2
    return 1
  }
  [ -n "$out" ] || {
    echo "::error::solver-pins.sh: $PINS_FILE names no cvc5 platform records" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# One definition of "take a sha256", because the two runners' coreutils differ:
# linux and Cygwin ship sha256sum, macOS ships shasum.  Both print
# "<hex>  <name>", which is the format `sha256sum -c` and `shasum -c` read, so
# a sidecar written on one platform verifies on another.
sha256_of () {
  if command -v sha256sum > /dev/null 2>&1
  then sha256sum "$@"
  else shasum -a 256 "$@"
  fi
}

# Verify a "<hex>  <name>" line, whichever tool this platform has.
sha256_check () {
  if command -v sha256sum > /dev/null 2>&1
  then sha256sum -c "$@"
  else shasum -a 256 -c "$@"
  fi
}
