#!/bin/bash
# Fetch the pinned cvc5 release for one unix leg, verify its digest, and leave
# the binary at ./cvc5-bin so every caller names it the same way.
#
#   release-fetch-cvc5.sh <asset-basename> <sha256-of-the-zip>
#
# The asset name and digest come from the workflow matrix, where all five are
# listed together and can be compared at a glance.  win-64 fetches its own
# (PowerShell, Get-FileHash) because that leg has no bash until Isabelle's
# Cygwin is up.
set -euo pipefail

asset=${1:?asset basename, e.g. cvc5-Linux-x86_64-static}
sha=${2:?sha256 of the zip}

# The pinned cvc5 SERIES.  >= 1.3.1 is required (the backend sends
# get-model-domain-elements, which older cvc5 answers with an error); the exact
# pin is asserted below so that changing the URL without changing the intent
# fails here rather than shipping.
CVC5_VERSION=1.3.4

die () { echo "::error::${0##*/}: $*"; exit 1; }

curl -sSL --retry 3 -o cvc5.zip \
  "https://github.com/cvc5/cvc5/releases/download/cvc5-$CVC5_VERSION/$asset.zip"

# macOS runners have no sha256sum; every platform has one of the two.
if command -v sha256sum > /dev/null 2>&1; then
  echo "$sha  cvc5.zip" | sha256sum -c
else
  echo "$sha  cvc5.zip" | shasum -a 256 -c
fi

unzip -q -o cvc5.zip
[ -f "$asset/bin/cvc5" ] || die "$asset/bin/cvc5 is not in the archive"
cp "$asset/bin/cvc5" cvc5-bin
chmod +x cvc5-bin

./cvc5-bin --version > cvc5-version.txt
head -1 cvc5-version.txt
# Measured on the pinned release: the first line is
# "cvc5 1.3.4 [git f3b21c4 on branch HEAD]".  Same substring the packaging
# recipe matches, so the two pins cannot silently disagree.
grep -q "cvc5 $CVC5_VERSION" cvc5-version.txt \
  || die "cvc5 reports '$(head -1 cvc5-version.txt)', expected cvc5 $CVC5_VERSION"
