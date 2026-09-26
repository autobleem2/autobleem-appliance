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
# docs/scanner-processors-plan.md; proc_unzip, the owner 2026-09-25):
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

# stage_extension REPO NAME KEY DEST [LAUNCHER] - an extension every package ships (the AutoBleem Store - the
# owner, 2026-09-25; it was a separate download): its package <repo name>-<KEY>-<v>.zip (Extensions/<NAME>/
# inside, bin/<KEY>/ only) unpacked to DEST/<NAME>/. Versions of its own, as a processor has: a development
# build (AB_SOURCE_TAG=nightly) takes the rolling `nightly`, a release its latest v* release - or its nightly
# while it has none yet. LAUNCHER, the binary it will be loaded into: their SDK stamps (AB_SDK_STAMP -
# "sdk=3;cxx=gcc-12;cxx11abi=1;target=win") must be the same, or the launcher would refuse the plugin at run
# time; a packed (UPX) launcher hides its stamp, and then only the plugin's own target is checked.
stage_extension() {
    local repo="$1" name="$2" key="$3" dest="$4" launcher="${5:-}" tag tmp stamp
    tag="${AB_SOURCE_TAG:-}"
    if [ -z "$tag" ]; then
        tag="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null)" || tag=""
        [ -n "$tag" ] || { tag=nightly; echo "    $repo has no release yet - its nightly is bundled"; }
    fi
    tmp="$(mktemp -d)"
    AB_SOURCE_TAG="$tag" fetch_release_assets "$repo" "$tag" "${repo##*/}-$key-*.zip" "$tmp" || return 1
    unzip -q "$tmp/${repo##*/}-$key-"*.zip -d "$tmp/x"
    [ -f "$tmp/x/Extensions/$name/extension.ini" ] || { echo "$repo's $key package lacks Extensions/$name/extension.ini" >&2; return 1; }
    stamp="$(check_extension_stamp "$tmp/x/Extensions/$name" "$name" "$key" "$launcher" "$repo@$tag")" || return 1
    mkdir -p "$dest"
    rm -rf "${dest:?}/$name"
    mv "$tmp/x/Extensions/$name" "$dest/$name"
    rm -rf "$tmp"
    echo "    bundled the $name extension ($repo@$tag, $stamp)"
}

# check_extension_stamp FOLDER NAME KEY LAUNCHER WHAT - FOLDER (an Extensions/<NAME>/) has a bin/<KEY>/<NAME>
# plugin whose SDK stamp names target KEY and, when LAUNCHER is given and readable, is the launcher's own
# stamp; prints the stamp. WHAT names the source in the messages ("repo@tag").
check_extension_stamp() {
    local folder="$1" name="$2" key="$3" launcher="$4" what="$5" plugin stamp theirs
    plugin="$(ls "$folder/bin/$key/$name".* 2>/dev/null | head -1)"
    [ -n "$plugin" ] || { echo "$what has no bin/$key/$name plugin" >&2; return 1; }
    stamp="$(grep -aoE 'sdk=[0-9]+;cxx=[a-z]+-[0-9]+;cxx11abi=[-0-9]+;target=[a-z0-9]+' "$plugin" | head -1)"
    [ -n "$stamp" ] || { echo "$plugin has no SDK stamp - not an extension?" >&2; return 1; }
    [ "${stamp##*target=}" = "$key" ] || { echo "$plugin is built for ${stamp##*target=}, not $key" >&2; return 1; }
    if [ -n "$launcher" ]; then
        theirs="$(grep -aoE 'sdk=[0-9]+;cxx=[a-z]+-[0-9]+;cxx11abi=[-0-9]+;target=[a-z0-9]+' "$launcher" | head -1 || true)"
        if [ -n "$theirs" ] && [ "$theirs" != "$stamp" ]; then
            echo "$what's plugin ($stamp) does not fit the launcher ($theirs) - rebuild it against the launcher" >&2
            return 1
        fi
        [ -n "$theirs" ] || echo "    (the launcher's SDK stamp is not readable - a packed binary; the plugin's is $stamp)" >&2
    fi
    printf '%s\n' "$stamp"
}

# stage_console_tools_extension KEY VERSION DEST [LAUNCHER] - PSC-Bios for a Pi or the PC stick (its Network &
# Controllers screens, over NetworkManager and BlueZ - 2026-09-26): autobleem-console-tools' package
# console-tools-<KEY>-<v>.tar.gz (Extensions/pscbios/ inside, bin/<KEY>/ only) unpacked to DEST/pscbios/.
# The console tools carry the unified version, so VERSION (or AB_SOURCE_TAG=nightly) picks the release, as
# for the launcher; the same SDK-stamp check as stage_extension.
stage_console_tools_extension() {
    local key="$1" version="$2" dest="$3" launcher="${4:-}" repo=autobleem2/autobleem-console-tools tmp stamp
    tmp="$(mktemp -d)"
    fetch_release_assets "$repo" "$version" "console-tools-$key-*.tar.gz" "$tmp" || return 1
    mkdir -p "$tmp/x"
    tar -xzf "$tmp"/console-tools-"$key"-*.tar.gz -C "$tmp/x"
    [ -f "$tmp/x/Extensions/pscbios/extension.ini" ] || { echo "console-tools-$key lacks Extensions/pscbios/extension.ini" >&2; return 1; }
    stamp="$(check_extension_stamp "$tmp/x/Extensions/pscbios" pscbios "$key" "$launcher" "console-tools-$key")" || return 1
    chmod +x "$tmp/x/Extensions/pscbios/bt" 2>/dev/null || true
    mkdir -p "$dest"
    rm -rf "${dest:?}/pscbios"
    mv "$tmp/x/Extensions/pscbios" "$dest/pscbios"
    rm -rf "$tmp"
    echo "    bundled the pscbios extension ($repo@${AB_SOURCE_TAG:-$version}, $stamp)"
}
