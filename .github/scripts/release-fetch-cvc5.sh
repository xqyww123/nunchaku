#!/bin/bash
# Fetch the pinned cvc5 release for one leg, verify its digest, and leave the
# binary at ./cvc5-bin so every caller names it the same way.
#
#   ISA_PLATFORM=x86_64-linux release-fetch-cvc5.sh
#
# The asset name, its digest and the version all come from component/solvers.pins,
# keyed on this leg's Isabelle platform.  Taking all three from one keyed record
# is what makes an x86_64 cvc5 on an arm64 leg unrepresentable: before, the
# asset/digest pair lived in the workflow matrix next to -- but not bound to --
# the platform id, and the version was a fourth literal in this script.
#
# win-64 does not run this script: that leg has no bash until Isabelle's Cygwin
# is up, and its cvc5 is a native Windows binary fetched from PowerShell.  It
# reads the SAME record -- main.yml exports it from a `shell: bash` step -- so
# there is still one table.
set -euo pipefail

: "${ISA_PLATFORM:?ISA_PLATFORM must name the Isabelle platform of this leg}"
SRC_ROOT=${SRC_ROOT:-$PWD}
# shellcheck source=.github/scripts/solver-pins.sh
. "$SRC_ROOT/.github/scripts/solver-pins.sh"

# Assign, then split.  `read -r asset sha <<< "$(pin ...)"` would take READ's
# exit status, so a missing or duplicated pins record would leave both fields
# empty with `set -e` none the wiser (solver-pins.sh's header records the
# measurement).
CVC5_VERSION=$(pin cvc5-version)
row=$(pin cvc5 "$ISA_PLATFORM")
read -r asset sha <<< "$row"

die () { echo "::error::${0##*/}: $*"; exit 1; }

# -f: without it a 404 or a 5xx writes the error page into cvc5.zip and curl
# still exits 0, so the digest check below fails with the wrong diagnosis, and
# --retry does not cover 5xx at all.
curl -fsSL --retry 3 -o cvc5.zip \
  "https://github.com/cvc5/cvc5/releases/download/cvc5-$CVC5_VERSION/$asset.zip"

echo "$sha  cvc5.zip" | sha256_check -

unzip -q -o cvc5.zip
[ -f "$asset/bin/cvc5" ] || die "$asset/bin/cvc5 is not in the archive"
cp "$asset/bin/cvc5" cvc5-bin
chmod +x cvc5-bin

./cvc5-bin --version > cvc5-version.txt
head -1 cvc5-version.txt
# Measured on the pinned release: the first line is
# "cvc5 1.3.4 [git f3b21c4 on branch HEAD]".  -F and the TRAILING SPACE, not a
# bare grep: unescaped dots make `cvc5 1.3.4` match `cvc5 1x3y4`, and without the
# delimiter it also matches `cvc5 1.3.44`.  The space is safe precisely because
# the measured line always has a token after the version.
grep -Fq "cvc5 $CVC5_VERSION " cvc5-version.txt \
  || die "cvc5 reports '$(head -1 cvc5-version.txt)', expected cvc5 $CVC5_VERSION"
