# Sourced by assemble.sh / assemble-psc.sh.
#
# fetch_release_assets REPO TAG GLOB DIR - download every asset of REPO's release TAG whose name matches the
# shell glob GLOB into DIR; fails when none matches.
#
# Not `gh release download`: that reads the asset list embedded in /releases/tags/<tag>, and on GitHub that
# list can go on missing an asset uploaded after the release was published, for good, while the release's
# own /releases/<id>/assets endpoint has it (seen 2026-09-23: launcher-psc and console-tools-psc attached to
# v2.0.0-alpha1 afterwards, "no assets match the file pattern" minutes later). The tag only resolves the id.
#
# AB_SOURCE_TAG, when set, is the release fetched from instead of TAG - `nightly` for a development build
# (every component's rolling pre-release of its develop branch), while VERSION still names what is assembled.
fetch_release_assets() {
    local repo="$1" tag="${AB_SOURCE_TAG:-$2}" glob="$3" dir="$4" id aid name n=0
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

# stage_processor REPO NAME DEST KEY... - a scanner processor bundled with every package (the launcher's
# docs/scanner-processors-plan.md; proc_unzip, the owner 2026-09-25: a processor ships, an extension does not):
# its package <NAME>-<v>.zip (the folder NAME/ with processor.ini and bin/<key>/ for every platform) unpacked to
# DEST/NAME/, keeping only the bin/<key>/ folders given. A processor has versions of its own, not the unified
# one: a development build (AB_SOURCE_TAG=nightly) takes its rolling `nightly`, a release its latest v* release
# - or its nightly while it has none yet.
stage_processor() {
    local repo="$1" name="$2" dest="$3" tag tmp
    shift 3
    tag="${AB_SOURCE_TAG:-}"
    if [ -z "$tag" ]; then
        # (a 404 prints its JSON on stdout: the output counts only when the call succeeded)
        tag="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null)" || tag=""
        [ -n "$tag" ] || { tag=nightly; echo "    $repo has no release yet - its nightly is bundled"; }
    fi
    tmp="$(mktemp -d)"
    AB_SOURCE_TAG="$tag" fetch_release_assets "$repo" "$tag" "$name-*.zip" "$tmp" || return 1
    mkdir -p "$dest"
    rm -rf "${dest:?}/$name"
    unzip -q "$tmp"/"$name"-*.zip -d "$dest"
    [ -f "$dest/$name/processor.ini" ] || { echo "$repo's package lacks $name/processor.ini" >&2; return 1; }
    local key keep bin
    for bin in "$dest/$name"/bin/*/; do
        key="$(basename "$bin")"
        keep=0
        for k in "$@"; do [ "$k" = "$key" ] && keep=1; done
        [ "$keep" = 1 ] || rm -rf "$bin"
    done
    ls "$dest/$name/bin" | grep -q . || { echo "$repo's package has no binary for $*" >&2; return 1; }
    chmod +x "$dest/$name"/bin/*/* 2>/dev/null || true
    rm -rf "$tmp"
    echo "    bundled $name ($repo@$tag) for $*"
}
