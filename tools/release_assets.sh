# Sourced by assemble.sh / assemble-psc.sh.
#
# fetch_release_assets REPO TAG GLOB DIR - download every asset of REPO's release TAG whose name matches the
# shell glob GLOB into DIR; fails when none matches.
#
# Not `gh release download`: that reads the asset list embedded in /releases/tags/<tag>, and on GitHub that
# list can go on missing an asset uploaded after the release was published, for good, while the release's
# own /releases/<id>/assets endpoint has it (seen 2026-09-23: launcher-psc and console-tools-psc attached to
# v2.0.0-alpha1 afterwards, "no assets match the file pattern" minutes later). The tag only resolves the id.
fetch_release_assets() {
    local repo="$1" tag="$2" glob="$3" dir="$4" id aid name n=0
    id="$(gh api "repos/$repo/releases/tags/$tag" --jq .id)" || { echo "no release $tag in $repo" >&2; return 1; }
    while IFS=$'\t' read -r aid name; do
        [ -n "$aid" ] || continue
        # shellcheck disable=SC2254 - GLOB is a pattern on purpose
        case "$name" in $glob) ;; *) continue ;; esac
        echo "    $repo@$tag: $name"
        gh api -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$aid" > "$dir/$name"
        n=$((n + 1))
    done < <(gh api --paginate "repos/$repo/releases/$id/assets" --jq '.[] | "\(.id)\t\(.name)"')
    [ "$n" -gt 0 ] || { echo "no asset matching $glob in $repo@$tag" >&2; return 1; }
}
