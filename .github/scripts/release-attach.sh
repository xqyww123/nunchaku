#!/bin/bash
# The release's asset contract, in one script and -- since the release-assets
# job replaced the per-leg attach steps -- executed in exactly one job.
#
#   release-attach.sh --list <isabelle-platform>   print that platform's five names
#   release-attach.sh collect <download-dir>       assemble and assert all 25 files
#   release-attach.sh publish                      create, upload, assert, un-draft
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
# sidecars, five version records.  `--list` is the external interface to that
# contract: isabelle-packaging-ci's RELEASE_CHECKLIST section 9 points the
# operator at it so no document has to restate the names.
#
# versions-<platform>.txt holds the two `--version` lines release-smoke.sh
# captured on this leg, under this platform's own runtime.  It exists because on
# x86_64-cygwin no other step in either repository can execute the two
# Cygwin-ABI binaries: without this file the packaging side's entire content
# check on them is that their first two bytes are "MZ", and the version and
# provenance claims made about them are prose.  release-smoke.sh asserts the
# record's shape where it is written; isabelle-packaging-ci asserts the nunchaku
# line's version field against the dispatched version and its 40-hex field
# against the tag's commit, on all five legs.
#
# On x86_64-cygwin the binary payload is a PE executable.  The asset name carries
# no `.exe`; the packaging recipe installs it as `nunchaku-bin.exe`, and the
# wrapper's `exec "$NUN_DIR/nunchaku-bin"` finds it because Cygwin appends the
# extension.
#
# WHY ONE JOB RATHER THAN FIVE LEGS.  Until this change each of the five legs
# ran `gh release create <tag> --draft || true` and then uploaded its own five
# files, under a comment claiming the first create wins and the rest are a
# harmless no-op.  That claim was never measured, and gh's own source does not
# support it for a draft: create looks for an existing release only when NOT
# --draft, and the lookup it uses is documented as returning "the first draft
# release" with that pending tag.  The fix is not a better test of gh -- the
# legs no longer touch the release at all.  They upload actions/upload-artifact
# artifacts; this script runs once, in the release-assets job, so there is
# exactly one `gh release create` in the whole workflow.  What that alone does
# not cover is a re-run of that job on a tag whose release already exists, so
# `publish` assumes nothing either: it COUNTS the release objects carrying this
# tag, creates one only when the count is zero, counts again, and refuses to
# upload unless the count is exactly one.  After the upload it re-reads the
# release and requires its asset list to be exactly the twenty-five names.
# Every one of those reads is `gh api` against
# `GET /repos/{owner}/{repo}/releases`, whose per-release `.id`, `.tag_name`,
# `.draft` and `.assets[].name` fields were measured 2026-08-25 against
# github.com; the un-draft is a PATCH on the counted `.id`, not a tag lookup.
# So no step here rests on a tag-to-draft resolution rule except
# `gh release upload <tag>`, and its OUTCOME is asserted immediately afterwards
# rather than assumed.
#
# Inputs, `collect`:  <download-dir>, the actions/download-artifact tree; each
#                     leg's artifact is nunchaku-<isabelle-platform>/.
#           SRC_ROOT  the repository checkout (defaults to $PWD)
# Inputs, `publish`:  GITHUB_REF, GITHUB_REF_NAME, GITHUB_REPOSITORY, GH_TOKEN,
#                     as GitHub Actions provides them, and the release-assets/
#                     directory `collect` left behind.
set -euo pipefail

die () { echo "::error::${0##*/}: $*"; exit 1; }

# The ONE definition of the per-platform file names.  `collect`, `publish` and
# `--list` all build their lists from this function, so "what the release must
# contain" cannot be stated twice and drift.
asset_names () {  # <isabelle-platform>
  local plat=$1
  printf '%s\n' \
    "nunchaku-bin-$plat" "nunchaku-bin-$plat.sha256" \
    "smbc-bin-$plat" "smbc-bin-$plat.sha256" \
    "versions-$plat.txt"
}

SRC_ROOT=${SRC_ROOT:-$PWD}
# Check before sourcing: every subcommand needs the pins, and a raw `source`
# failure from the wrong directory is a bash line number rather than an
# instruction.  This is the case the release procedure warns about (--list is
# typed by hand, from whichever checkout the operator happens to be in).
[ -r "$SRC_ROOT/.github/scripts/solver-pins.sh" ] \
  || die "$SRC_ROOT does not look like the fork checkout: no .github/scripts/solver-pins.sh.  Run from the fork, or set SRC_ROOT to it."
# shellcheck source=.github/scripts/solver-pins.sh
. "$SRC_ROOT/.github/scripts/solver-pins.sh"

if [ "${1-}" = --list ]; then
  want=${2:?--list needs an Isabelle platform id}
  # Validated against the pins table: an operator following section 9 step 1
  # types this by hand, and an unknown platform would otherwise print a
  # plausible five-line contract for a platform the release does not have.
  pin_platforms | grep -Fqx -- "$want" \
    || die "unknown platform '$want'; component/solvers.pins names: $(pin_platforms | tr '\n' ' ')"
  asset_names "$want"
  exit 0
fi

# The staging directory `collect` fills and `publish` uploads.  Both derive it
# the same way, so the two subcommands cannot disagree about where the assets
# are.
OUT=$PWD/release-assets

# The 25 contracted names, from the platform list in component/solvers.pins and
# the name list above.  ASSIGN, then iterate: `while read ... < <(pin_platforms)`
# would discard pin_platforms' exit status, and a pins file that cannot be read
# would silently produce an empty contract that every later diff agrees with.
expected_names () {
  local plats plat
  plats=$(pin_platforms) || return 1
  while IFS= read -r plat; do
    [ -n "$plat" ] || continue
    asset_names "$plat"
  done <<< "$plats"
}

case "${1-}" in
  collect)
    dl=${2:?collect needs the actions/download-artifact directory}
    [ -d "$dl" ] || die "$dl is not a directory"
    rm -rf "$OUT"
    mkdir -p "$OUT"

    plats=$(pin_platforms)
    while IFS= read -r plat; do
      [ -n "$plat" ] || continue
      leg="$dl/nunchaku-$plat"
      # An absent artifact directory is a leg that never ran or never uploaded.
      # `needs:` already refuses to start this job unless both build families
      # are green, so this fires on a leg that went green without producing --
      # the only remaining way to reach a partial release.
      [ -d "$leg" ] || die "the $plat leg produced no artifact ($leg is missing)"
      for stem in nunchaku-bin smbc-bin; do
        [ -s "$leg/$stem" ] || die "$plat: $leg/$stem is missing or empty"
        # The digest comes from the leg that built the binary
        # (release-smoke.sh), and is VERIFIED here rather than recomputed:
        # recomputing would only certify whatever came back out of
        # actions/download-artifact.  On x86_64-cygwin this is the only check
        # on the binary's bytes anywhere in the two repositories -- nothing
        # ever executes a Cygwin binary, so the packaging side's own content
        # check is the two bytes `MZ`.
        [ -s "$leg/$stem.sha256" ] \
          || die "$plat: $leg/$stem.sha256 is missing -- release-smoke.sh did not digest what it built"
        ( cd "$leg" && sha256_check "$stem.sha256" > /dev/null ) \
          || die "$plat: $stem does not match the digest its own leg recorded"
        cp "$leg/$stem" "$OUT/$stem-$plat"
        # The released sidecar carries that same digest under the released
        # name, so the hex a consumer checks is the one the producing leg
        # measured.  The name is the bare asset name, as 0.5.2's was.
        printf '%s  %s\n' "$(cut -d' ' -f1 < "$leg/$stem.sha256")" "$stem-$plat" \
          > "$OUT/$stem-$plat.sha256"
        ( cd "$OUT" && sha256_check "$stem-$plat.sha256" > /dev/null ) \
          || die "$plat: the released $stem-$plat does not match the digest its leg recorded"
      done
      # Named for THIS platform, inside THIS platform's artifact: a leg that
      # wrote another platform's record cannot satisfy both halves.
      [ -s "$leg/versions-$plat.txt" ] \
        || die "$plat: $leg/versions-$plat.txt is missing or empty -- release-smoke.sh did not run"
      cp "$leg/versions-$plat.txt" "$OUT/versions-$plat.txt"
    done <<< "$plats"

    expected_names | sort > contract.txt
    # What is actually in the staging directory -- ANY extra file is a diff, so
    # this is `find`, not a re-listing of the names we just wrote.
    ( cd "$OUT" && find . -maxdepth 1 ! -name . ) | sed 's|^\./||' | sort > assembled.txt
    if ! diff -u contract.txt assembled.txt; then
      die "the assembled asset set is not exactly the contracted files"
    fi
    echo "the contract names $(wc -l < contract.txt) files, and all of them were assembled:"
    ( cd "$OUT" && ls -l )
    echo "=== version records ==="
    for f in "$OUT"/versions-*.txt; do
      echo "-- ${f##*/}"
      cat "$f"
    done
    ;;

  publish)
    : "${GITHUB_REF:?}" "${GITHUB_REF_NAME:?}" "${GITHUB_REPOSITORY:?}"
    [ -d "$OUT" ] || die "$OUT is missing -- run 'collect' first"

    version=$(cat "$SRC_ROOT/VERSION")
    # The tag must agree with the VERSION single source: without this a tag
    # could publish binaries whose --version disagrees with the release name.
    [ "refs/tags/v$version" = "$GITHUB_REF" ] \
      || die "tag '$GITHUB_REF' does not match VERSION 'v$version'"

    names=$(expected_names)
    assets=()
    while IFS= read -r a; do
      [ -f "$OUT/$a" ] || die "the contract names $a and collect did not produce it"
      assets+=("$OUT/$a")
    done <<< "$names"

    # Every read below is this one documented endpoint.  Measured 2026-08-25
    # against github.com (`gh api repos/xqyww123/nunchaku/releases`): each
    # element carries .id, .tag_name, .draft and .assets[].name.
    export TAG=$GITHUB_REF_NAME
    release_ids () {   # "<id> <draft>" per release carrying the tag
      gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
        --jq '.[] | select(.tag_name == env.TAG) | "\(.id) \(.draft)"'
    }
    count_ids () {  # <newline-separated ids>  -- 0 for the empty string
      [ -n "$1" ] || { echo 0; return 0; }
      printf '%s\n' "$1" | wc -l | tr -d ' '
    }

    ids=$(release_ids)
    before=$(count_ids "$ids")
    echo "releases carrying $TAG before create: $before"
    if [ "$before" -eq 0 ]; then
      gh release create "$TAG" --draft \
        --notes "See PATCHES.md for the patch set."
      ids=$(release_ids)
    else
      # A re-run of this job, or a recovery pass: do not create a second one.
      echo "a release for $TAG already exists; not creating another"
    fi

    n=$(count_ids "$ids")
    [ "$n" -eq 1 ] || die "expected exactly one release for $TAG, found $n:
$ids"
    id=${ids%% *}
    draft=${ids##* }
    echo "release id for $TAG: $id (draft: $draft)"

    # REFUSE, rather than re-upload, once the release is out of draft.  Two
    # reasons, and only the second is what the guard rests on.
    #
    # (1) A rebuild is not bit-for-bit.  Measured 2026-08-26 on the maintainer's
    # machine: two builds of one commit with `rm -rf _build` between them differ
    # in 89 bytes -- the GNU build-id note plus three digest-shaped regions.  A
    # rebuild that restores from dune's shared cache instead of compiling can of
    # course come back identical, which is why this is stated as measured on a
    # cold build rather than as a property of the project.
    #
    # (2) Whether or not the bytes match, nothing downstream compares them.  The
    # conda packages are immutable and their digests were taken once, from the
    # assets that were on the release at the time; replacing a published asset
    # ends that correspondence silently, with every gate still green.  That
    # holds even for an identical rebuild, so it -- not (1) -- is the reason.
    # Recovery for a published release is a new patch
    # version, not a second pass over this one (RELEASE_CHECKLIST.md section 9
    # step 3).
    if [ "$draft" != true ]; then
      # Published already.  That is either "this job finished and is being
      # re-run", in which case the release carries exactly the contract and
      # there is nothing left to do, or "freshly built, differing binaries are
      # about to replace a published release's assets", which must not happen:
      # the conda channel's immutable packages would then be certified by bytes
      # the release no longer serves.  The contract diff tells the two apart,
      # so ask it rather than refusing both.
      gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
        --jq '.[] | select(.tag_name == env.TAG) | .assets[].name' \
        | sort > uploaded.txt
      printf '%s\n' "$names" | sort > contract.txt
      if diff -q contract.txt uploaded.txt > /dev/null; then
        echo "$TAG is already published and carries exactly the $(wc -l < contract.txt) contracted assets; nothing to do"
        exit 0
      fi
      diff -u contract.txt uploaded.txt || true
      die "the release for $TAG is already published and does not carry the contract; its assets must not be replaced with freshly built, differing binaries -- fix forward with a new patch version (RELEASE_CHECKLIST.md section 9, the release-run plan, step 3 'Wait for the fork's release-assets job')"
    fi

    # --clobber is KEPT, deliberately.  The recovery path RELEASE_CHECKLIST.md
    # prescribes for a red job is "re-run failed jobs", and a re-run reuses the
    # run: without --clobber a second pass over an already-uploaded asset
    # reddens.  What binds the release to the tag is not the sidecar but
    # content: versions-<platform>.txt carries the commit each binary
    # self-reports, and the packaging side checks that against the tag.
    gh release upload "$TAG" "${assets[@]}" --clobber

    # `gh release upload` resolves the tag to a release itself, and how it does
    # that for a draft is not something this repository has measured.  It does
    # not have to be: with exactly one release for the tag there is only one it
    # can reach, and the outcome is asserted here rather than assumed.
    gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
      --jq '.[] | select(.tag_name == env.TAG) | .assets[].name' \
      | sort > uploaded.txt
    printf '%s\n' "$names" | sort > contract.txt
    if ! diff -u contract.txt uploaded.txt; then
      die "the release does not carry exactly the contracted files"
    fi

    # Only now does v<version> become visible to the packaging repository, and
    # by id, so this cannot un-draft something else that happens to share a tag.
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$id" -F draft=false > /dev/null
    echo "$TAG: $(wc -l < contract.txt) assets asserted, release taken out of draft"
    ;;

  *)
    die "usage: ${0##*/} --list <platform> | collect <download-dir> | publish -- run from the fork checkout, or set SRC_ROOT to it: every subcommand reads component/solvers.pins through .github/scripts/solver-pins.sh"
    ;;
esac
