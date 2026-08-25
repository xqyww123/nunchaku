#!/bin/bash
# Attach one platform's release files to the GitHub release for the pushed tag,
# and -- with --list -- print the contracted names for any platform without
# touching anything.  Every leg calls this, and so does the release gate, so the
# asset-name contract has exactly one definition in the repository.
#
# THE CONTRACT.  For each platform the release carries five files:
#
#     nunchaku-bin-<isabelle-platform>   nunchaku-bin-<isabelle-platform>.sha256
#     smbc-bin-<isabelle-platform>       smbc-bin-<isabelle-platform>.sha256
#     versions-<isabelle-platform>.txt
#
# with <isabelle-platform> one of the five in component/solvers.pins.  That is
# the ISABELLE platform identifier, not the conda subdir, and it is deliberate:
# the same string names the component's platform directory, so the release asset
# and the packaged path cannot drift apart.  x86_64-linux keeps exactly the name
# 0.5.2 used, so the existing consumer keeps working unchanged.  Five platforms
# times five files is TWENTY-FIVE release assets: ten binaries, ten .sha256
# sidecars, five version records.
#
# versions-<platform>.txt holds the two `--version` lines release-smoke.sh
# captured on this leg, under this platform's own runtime.  It exists because on
# x86_64-cygwin no other step in either repository can execute the two
# Cygwin-ABI binaries: without this file the packaging side's entire content
# check on them is that their first two bytes are "MZ", and the version and
# provenance claims made about them are prose.  isabelle-packaging-ci asserts
# the nunchaku line's version field against the dispatched version and its
# 40-hex field against the tag's commit, on all five legs.
#
# On x86_64-cygwin the binary payload is a PE executable.  The asset name carries
# no `.exe`; the packaging recipe installs it as `nunchaku-bin.exe`, and the
# wrapper's `exec "$NUN_DIR/nunchaku-bin"` finds it because Cygwin appends the
# extension.
#
# Inputs:
#   ISA_PLATFORM  Isabelle platform id of this leg
#   GITHUB_REF    the pushed ref (must be refs/tags/v<VERSION>)
#   GITHUB_REF_NAME, GH_TOKEN   as GitHub Actions provides them
set -euo pipefail

die () { echo "::error::${0##*/}: $*"; exit 1; }

# The ONE definition of the per-platform file names.  Both the upload below and
# the release-gate job build their lists from this function, so "what the
# release must contain" cannot be stated twice and drift.
asset_names () {  # <isabelle-platform>
  local plat=$1
  printf '%s\n' \
    "nunchaku-bin-$plat" "nunchaku-bin-$plat.sha256" \
    "smbc-bin-$plat" "smbc-bin-$plat.sha256" \
    "versions-$plat.txt"
}

if [ "${1-}" = --list ]; then
  asset_names "${2:?--list needs an Isabelle platform id}"
  exit 0
fi

: "${ISA_PLATFORM:?}" "${GITHUB_REF:?}" "${GITHUB_REF_NAME:?}"

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

for stem in nunchaku-bin smbc-bin; do
  [ -f "$stem" ] || die "$stem was not built"
  asset="$stem-$ISA_PLATFORM"
  cp "$stem" "$asset"
  sha256_into "$asset" "$asset.sha256"
done
# Written by release-smoke.sh, which is the only step that can run both binaries
# on this platform.  A leg that reached here without it would be attaching
# binaries nothing executed.
[ -f "versions-$ISA_PLATFORM.txt" ] \
  || die "versions-$ISA_PLATFORM.txt is missing -- release-smoke.sh did not run"
cat -- *"-$ISA_PLATFORM.sha256" "versions-$ISA_PLATFORM.txt"

# A read loop, not `mapfile`: the macOS legs run bash 3.2 (Apple's /bin/bash),
# where mapfile does not exist and the array would silently stay empty.
assets=()
while IFS= read -r a; do assets+=("$a"); done < <(asset_names "$ISA_PLATFORM")
for a in "${assets[@]}"; do
  [ -f "$a" ] || die "the contract names $a and this leg did not produce it"
done

# --draft.  Without it the FIRST leg to finish publishes a live v<version>
# carrying whatever has been attached so far, and with fail-fast off and win-64
# in its own job, a release that ends up two-fifths built is still announced as
# a release.  The `release-gate` job in main.yml asserts the full twenty-five
# and only then takes it out of draft.
#
# Every leg races to create the release; the first wins and the rest are a
# harmless no-op, hence `|| true`.  The upload below is the step that must
# succeed.
gh release create "$GITHUB_REF_NAME" --draft \
  --notes "See PATCHES.md for the patch set." || true
# --clobber is KEPT, deliberately.  The recovery path RELEASE_CHECKLIST.md
# prescribes for a red leg is "re-run failed jobs", and a re-run reuses the run:
# without --clobber any leg that had already uploaded would redden on its second
# pass.  The mutability that buys is not what binds the release to the tag --
# the .sha256 sidecar cannot do that, since this same job writes and uploads
# both.  What binds it is content: versions-<platform>.txt carries the commit
# the binary self-reports, and the packaging side checks that against the tag.
gh release upload "$GITHUB_REF_NAME" "${assets[@]}" --clobber
