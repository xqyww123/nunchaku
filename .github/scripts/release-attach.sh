#!/bin/bash
# Attach one platform's pair of binaries to the GitHub release for the pushed
# tag.  Every leg calls this, so the asset-name contract has exactly one
# definition in the repository.
#
# THE CONTRACT.  For each platform the release carries four files:
#
#     nunchaku-bin-<isabelle-platform>   nunchaku-bin-<isabelle-platform>.sha256
#     smbc-bin-<isabelle-platform>       smbc-bin-<isabelle-platform>.sha256
#
# with <isabelle-platform> one of x86_64-linux, arm64-linux, x86_64-darwin,
# arm64-darwin, x86_64-cygwin.  That is the ISABELLE platform identifier, not
# the conda subdir, and it is deliberate: the same string names the component's
# platform directory, so the release asset and the packaged path cannot drift
# apart.  x86_64-linux keeps exactly the name 0.5.2 used, so the existing
# consumer keeps working unchanged.
#
# On x86_64-cygwin the payload is a PE executable.  The asset name carries no
# `.exe`; the packaging recipe installs it as `nunchaku-bin.exe`, and the
# wrapper's `exec "$NUN_DIR/nunchaku-bin"` finds it because Cygwin appends the
# extension.
#
# Inputs:
#   ISA_PLATFORM  Isabelle platform id of this leg
#   GITHUB_REF    the pushed ref (must be refs/tags/v<VERSION>)
#   GITHUB_REF_NAME, GH_TOKEN   as GitHub Actions provides them
set -euo pipefail

: "${ISA_PLATFORM:?}" "${GITHUB_REF:?}" "${GITHUB_REF_NAME:?}"

die () { echo "::error::${0##*/}: $*"; exit 1; }

version=$(cat VERSION)
# The tag must agree with the VERSION single source, on every leg -- a leg that
# skipped this could attach a binary whose --version disagrees with the release.
[ "refs/tags/v$version" = "$GITHUB_REF" ] \
  || die "tag $GITHUB_REF does not match VERSION $version"

sha256_into () {  # <file> <output>
  # macOS runners have no sha256sum; both tools print "<hash>  <name>", which
  # is the format the packaging repository's `cut -d' ' -f1` expects.
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" > "$2"
  else
    shasum -a 256 "$1" > "$2"
  fi
}

assets=()
for stem in nunchaku-bin smbc-bin; do
  [ -f "$stem" ] || die "$stem was not built"
  asset="$stem-$ISA_PLATFORM"
  cp "$stem" "$asset"
  sha256_into "$asset" "$asset.sha256"
  assets+=("$asset" "$asset.sha256")
done
cat -- *"-$ISA_PLATFORM.sha256"

# Every leg races to create the release; the first wins and the rest are a
# harmless no-op, hence `|| true`.  The upload below is the step that must
# succeed.
gh release create "$GITHUB_REF_NAME" --notes "See PATCHES.md for the patch set." || true
gh release upload "$GITHUB_REF_NAME" "${assets[@]}" --clobber
