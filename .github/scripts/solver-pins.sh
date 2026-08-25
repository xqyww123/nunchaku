#!/bin/bash
# Read one record out of component/solvers.pins.  SOURCED, never executed --
# every release script that needs a solver pin gets it from here, so the pins
# have exactly one parser as well as exactly one definition.
#
#   . "$SRC_ROOT/.github/scripts/solver-pins.sh"
#   ver=$(pin cvc5-version)                    # -> 1.3.4
#   read -r asset sha <<< "$(pin cvc5 x86_64-linux)"
#   pin_platforms                              # -> the five Isabelle platform ids
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
  awk '$1 == "cvc5" { print $2 }' "$PINS_FILE"
}
