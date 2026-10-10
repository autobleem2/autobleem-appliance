#!/usr/bin/env bash
# launcher_sdk.sh REF | --from-header FILE - the extension ABI number (AB_SDK_ABI) of a launcher build.
#
#   launcher_sdk.sh --from-header extension.h   print the number #define'd as AB_SDK_ABI in that header
#   launcher_sdk.sh REF                         REF = the launcher's git describe (v2.0.0-alpha1-45-g7761e82), a
#                                               commit or a tag of autobleem2/autobleem: read the autobleem-core
#                                               submodule's sha at that commit (.gitmodules gives its path), then
#                                               src/code/gui/extension.h of autobleem-core at that sha (gh api)
#
# The number tools/check_image.sh --sdk takes: what the launcher and the extensions of THIS build were compiled
# against, i.e. the autobleem-core pin of the launcher commit - never a release/*.lock (an old release's lock
# names an old number). AB_LAUNCHER_REPO / AB_CORE_REPO override the repositories (autobleem2/autobleem,
# autobleem2/autobleem-core). Prints only the number; exit 1 and a message on stderr when it cannot be found.
set -uo pipefail

die() { echo "launcher_sdk.sh: $*" >&2; exit 1; }

# the number of the "#define AB_SDK_ABI N" line (a comment that mentions the name does not count)
sdk_from_header() {
    local n
    n="$(sed -n 's/^[[:space:]]*#[[:space:]]*define[[:space:]][[:space:]]*AB_SDK_ABI[[:space:]][[:space:]]*\([0-9][0-9]*\)\([^0-9A-Za-z_].*\)\{0,1\}$/\1/p' | head -1)"
    [ -n "$n" ] || return 1
    echo "$n"
}

case "${1:-}" in
    --from-header)
        [ -f "${2:-}" ] || die "no such header: ${2:-<none>}"
        sdk_from_header <"$2" || die "$2 has no '#define AB_SDK_ABI <number>'"
        exit 0 ;;
    ""|-*) die "usage: launcher_sdk.sh REF | --from-header FILE" ;;
esac

ref="$1"
# a git describe names the commit after "-g": v2.0.0-alpha1-45-g7761e82 -> 7761e82; a plain tag stays a tag
if [[ "$ref" =~ -g([0-9a-f]{7,40})$ ]]; then ref="${BASH_REMATCH[1]}"; fi
launcher="${AB_LAUNCHER_REPO:-autobleem2/autobleem}"
core="${AB_CORE_REPO:-autobleem2/autobleem-core}"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
raw=(-H 'Accept: application/vnd.github.raw')

gm="$(gh api "${raw[@]}" "repos/$launcher/contents/.gitmodules?ref=$ref")" \
    || die "cannot read .gitmodules of $launcher at $ref"
path="$(awk '/^\[submodule /{ s = ($0 ~ /"autobleem-core"/) } s && $1 == "path" { print $3; exit }' <<<"$gm")"
[ -n "$path" ] || die "$launcher's .gitmodules at $ref has no autobleem-core submodule"
sha="$(gh api "repos/$launcher/contents/$path?ref=$ref" --jq 'select(.type == "submodule") | .sha')" \
    || die "cannot read the $path entry of $launcher at $ref"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "$launcher's $path at $ref is not a submodule commit (got '$sha')"
hdr="$(gh api "${raw[@]}" "repos/$core/contents/src/code/gui/extension.h?ref=$sha")" \
    || die "cannot read src/code/gui/extension.h of $core at $sha"
sdk_from_header <<<"$hdr" || die "$core's extension.h at $sha has no '#define AB_SDK_ABI <number>'"
