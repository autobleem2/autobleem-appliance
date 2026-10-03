#!/usr/bin/env bash
# check_release.sh LOCK DIST... - check built packages against a release lock (release/<version>.lock).
#
# Each DIST is a folder holding built packages (the launcher's dist/, ext_store's dist/, console-tools' dist/, or
# the appliance's output). Recognised: dist/<target>/Autobleem (an unpacked package folder), autobleem-psc-*.zip|tar.gz,
# autobleem-win-product-*.zip, autobleem-win-*.zip, AutoBleemSetup-*.exe, autobleem-{rpi,rpi-arm64,pcusb}-*.tar.gz,
# ext_store-<target>-*.zip, console-tools-<target>-*.tar.gz. Everything is unpacked to a temp folder and read, never
# changed. One PASS / FAIL / SKIP line per check; exit 1 when any check FAILs. Needs bash 4, unzip, tar, grep, awk.
# Format of the lock and what each check can and cannot see: release/README.md.
set -uo pipefail
LOCK="${1:-}"; shift || true
[ -f "$LOCK" ] && [ $# -gt 0 ] || { echo "usage: $0 LOCK DIST..." >&2; exit 2; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
passes=0; fails=0
pass() { passes=$((passes + 1)); echo "PASS $1: $2"; }
fail() { fails=$((fails + 1)); echo "FAIL $1: $2"; }
skip() { echo "SKIP $1: $2"; }
# lock SECTION KEY - the value of `key = value` in [section]
lock() { awk -F'=' -v s="[$1]" -v k="$2" '/^\[/ { sec = $0 } sec == s { key = $1; gsub(/ /, "", key); if (key == k) { sub(/^[^=]*= */, ""); sub(/ +$/, ""); print; exit } }' "$LOCK"; }
# expect LABEL WHAT EXPECTED GOT
expect() { if [ "$3" = "$4" ]; then pass "$1" "$2 = $3"; else fail "$1" "$2: expected $3, got ${4:-nothing}"; fi; }

VERSION="$(lock release version)"; CHANNEL="$(lock release channel)"; SDK="$(lock release sdk)"
COMMIT="$(lock launcher commit)"
[ -n "$VERSION" ] && [ -n "$CHANNEL" ] && [ -n "$SDK" ] || { echo "$LOCK: release version/channel/sdk missing" >&2; exit 2; }

stamp_of() { grep -aoE 'sdk=[0-9]+;cxx=[a-z]+-[0-9]+;cxx11abi=[-0-9]+;target=[a-z0-9]+' "$1" | head -1; }
version_tokens() { grep -aoE 'v[0-9]+\.[0-9]+\.[0-9]+[-A-Za-z0-9._]*' "$1" | sort -u; }
launcher_of() { find "$1" -type f \( -name autobleem-gui -o -name autobleem-gui.exe \) | head -1; }

# check_version_text LABEL WHAT TEXT - TEXT is the lock's version, optionally followed by -<launcher commit hash>;
# a prerelease/release package never carries nightly or dirty
check_version_text() {
    local label="$1" what="$2" text="$3" rest hash
    case "$CHANNEL" in prerelease | release)
        case "$text" in *nightly* | *dirty*) fail "$label" "$what '$text' names nightly/dirty in a $CHANNEL package"; return ;; esac ;;
    esac
    rest="${text#"$VERSION"}"
    if [ "$rest" = "$text" ]; then fail "$label" "$what: expected $VERSION, got ${text:-nothing}"
    elif [ -z "$rest" ]; then pass "$label" "$what = $text"
    else
        hash="${rest#-}"
        if [[ "$rest" == -* && "$hash" =~ ^[0-9a-f]{7,40}$ && "$hash" == "$COMMIT"* ]]; then pass "$label" "$what = $text (launcher commit $COMMIT)"
        else fail "$label" "$what '$text': expected $VERSION or $VERSION-<hash starting $COMMIT>"; fi
    fi
}

declare -A LSTAMP   # target -> the launcher's SDK stamp, for the extension checks
T_LABEL=(); T_TARGET=(); T_DIR=(); T_REQ_EMU=()
# add_tree LABEL TARGET DIR REQUIRE_EMULATORS(0|1)
add_tree() {
    local bin s
    T_LABEL+=("$1"); T_TARGET+=("$2"); T_DIR+=("$3"); T_REQ_EMU+=("$4")
    bin="$(launcher_of "$3")"
    if [ -n "$bin" ]; then s="$(stamp_of "$bin")"; [ -n "$s" ] && LSTAMP[$2]="$s"; fi
}
# unpack LABEL TARGET FILE REQUIRE_EMULATORS
unpack() {
    local dest="$work/$((${#T_LABEL[@]} + 1))-$1"
    mkdir -p "$dest"
    case "$3" in
        *.zip) unzip -q -o "$3" -d "$dest" ;;
        *.tar.gz) tar -xzf "$3" -C "$dest" ;;
    esac
    # (unzip returns 1 for warnings - the odd file name - and the tree is still readable)
    [ -n "$(ls -A "$dest")" ] || { fail "$1" "could not unpack $(basename "$3")"; return; }
    add_tree "$1" "$2" "$dest" "$4"
}

for dist in "$@"; do
    [ -d "$dist" ] || { fail "$dist" "not a folder"; continue; }
    for sub in psc pcusb rpi rpi64 win; do
        [ -d "$dist/$sub/Autobleem" ] || [ -d "$dist/$sub/AutoBleem" ] || continue
        add_tree "$sub" "$sub" "$dist/$sub" "$([ "$sub" = psc ] && echo 1 || echo 0)"
    done
    while IFS= read -r f; do
        b="$(basename "$f")"
        case "$b" in
            autobleem-psc-*.zip) unpack psc-zip psc "$f" 1 ;;
            autobleem-psc-*.tar.gz) unpack psc-tar psc "$f" 1 ;;
            autobleem-win-product-*.zip) unpack win-product win "$f" 1 ;;
            # the plain win zip is the dev-host build (AB_TARGET unset, stamp target=dev) for our own PC tests -
            # it is not released (2026-10-03), so it is not checked; the product zip and the installer are
            autobleem-win-*.zip) echo "SKIP win-package: $b is the dev-host build, not a release package" ;;
            autobleem-rpi-arm64-*.tar.gz) unpack rpi64-pkg rpi64 "$f" 0 ;;
            autobleem-rpi-armhf-*.tar.gz) unpack rpi-pkg rpi "$f" 0 ;;
            autobleem-pcusb-i386-*.tar.gz) unpack pcusb-pkg pcusb "$f" 0 ;;
            ext_store-*-*.zip) t="${b#ext_store-}"; unpack "ext_store-${t%%-*}" "${t%%-*}" "$f" 0 ;;
            console-tools-*-*.tar.gz) t="${b#console-tools-}"; unpack "console-tools-${t%%-*}" "${t%%-*}" "$f" 0 ;;
            AutoBleemSetup-*.exe) t="${b#AutoBleemSetup-}"; check_version_text win-installer "file name" "${t%.exe}" ;;
        esac
    done < <(find "$dist" -maxdepth 2 -type f | sort)
done

# check_launcher LABEL TARGET TREE BIN
check_launcher() {
    local label="$1" target="$2" tree="$3" bin="$4" vfile text tokens s bad
    vfile="$(find "$tree" -maxdepth 2 -type f -name VERSION | head -1)"
    if [ -z "$vfile" ]; then fail "$label" "no VERSION file (a stick keeps its old one and the corner tag says TESTING)"
    else check_version_text "$label" "VERSION file" "$(head -1 "$vfile" | tr -d '\r')"; fi
    if [ -f "$tree/BUILD.txt" ]; then
        text="$(sed -n '1s/^AutoBleem \(.*\) - \([a-z0-9]*\)\r\?$/\1 \2/p' "$tree/BUILD.txt")"
        check_version_text "$label" "BUILD.txt version" "${text% *}"
        expect "$label" "BUILD.txt target" "$target" "${text##* }"
    fi
    if grep -aqF 'UPX!' "$bin"; then
        skip "$label" "launcher is UPX-packed: its version, channel and SDK stamp are not readable (the VERSION file is all there is)"
        return
    fi
    tokens="$(version_tokens "$bin")"
    if grep -qxF "$VERSION" <<<"$tokens"; then pass "$label" "launcher binary shows version $VERSION"
    else fail "$label" "launcher binary version: expected $VERSION, found: $(grep -E 'alpha|beta|rc|nightly|dirty' <<<"$tokens" | tr '\n' ' ')"; fi
    case "$CHANNEL" in prerelease | release)
        bad="$(grep -E 'nightly|dirty' <<<"$tokens" | tr '\n' ' ')"
        [ -z "$bad" ] && pass "$label" "launcher version strings carry no nightly/dirty" || fail "$label" "launcher version strings: $bad" ;;
    esac
    # (weak: the channel names also sit in the binary as the names it compares with, so this proves the word is
    # there, not which one the build was given - see release/README.md)
    if grep -aqF "$CHANNEL" "$bin"; then pass "$label" "launcher binary has the channel string '$CHANNEL'"
    else fail "$label" "launcher binary has no '$CHANNEL' channel string"; fi
    s="${LSTAMP[$target]:-}"
    if [ -z "$s" ]; then skip "$label" "launcher SDK stamp not readable (packed binary?)"
    else
        expect "$label" "launcher stamp sdk" "$SDK" "$(sed 's/^sdk=\([0-9]*\);.*/\1/' <<<"$s")"
        expect "$label" "launcher stamp target" "$target" "${s##*target=}"
    fi
}

# check_emulators LABEL TARGET TREE REQUIRED
check_emulators() {
    local label="$1" target="$2" tree="$3" required="$4" name bin want got note=""
    [ "$target" = win ] && note=" (win takes its emulators from the site's latest.json - tools/make_win_package.sh, not from the lock)"
    for name in emunxt emu; do
        want="$(lock "$name" describe)"
        bin="$(find "$tree" -type f \( -path "*/$name/pcsx-ab" -o -path "*/$name/pcsx-ab.exe" \) | head -1)"
        if [ -z "$bin" ]; then
            [ "$required" = 1 ] && fail "$label" "no $name/pcsx-ab in the package" || skip "$label" "no $name emulator in this package"
        elif grep -aqF "$want" "$bin"; then pass "$label" "$name stamp = $want"
        else
            got="$(grep -aoE 'v[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9.-]+' "$bin" | sort -u | head -3 | tr '\n' ' ')"
            fail "$label" "$name stamp: expected $want, found ${got:-no version stamp}$note"
        fi
    done
}

# check_extensions LABEL TARGET TREE - every bundled extension plugin (Extensions/<name>/bin/<key>/<name>.so|dll)
check_extensions() {
    local label="$1" target="$2" tree="$3" plugin dir name key s want ini
    while IFS= read -r plugin; do
        dir="$(dirname "$(dirname "$(dirname "$plugin")")")"; name="$(basename "$dir")"; key="$(basename "$(dirname "$plugin")")"
        s="$(stamp_of "$plugin")"
        if [ -z "$s" ]; then fail "$label" "extension $name: $(basename "$plugin") has no SDK stamp"; continue; fi
        expect "$label" "extension $name stamp sdk" "$SDK" "$(sed 's/^sdk=\([0-9]*\);.*/\1/' <<<"$s")"
        expect "$label" "extension $name stamp target" "$target" "${s##*target=}"
        [ "$key" = "$target" ] || fail "$label" "extension $name sits in bin/$key, the package is $target"
        if [ -n "${LSTAMP[$target]:-}" ]; then expect "$label" "extension $name stamp = launcher stamp" "${LSTAMP[$target]}" "$s"; fi
        case "$name" in store) want="$(lock ext_store version)" ;; pscbios) want="$(lock pscbios version)" ;; *) want="" ;; esac
        ini="$dir/extension.ini"
        if [ -z "$want" ]; then skip "$label" "extension $name: not in the lock"
        else expect "$label" "extension $name version" "$want" "$(sed -n 's/^Version=\(.*\)\r\?$/\1/p' "$ini" 2>/dev/null | head -1)"; fi
    done < <(find "$tree" -type f -ipath '*/extensions/*/bin/*/*' \( -name '*.so' -o -name '*.dll' \) | sort)
}

for i in "${!T_LABEL[@]}"; do
    label="${T_LABEL[$i]}"; target="${T_TARGET[$i]}"; tree="${T_DIR[$i]}"
    bin="$(launcher_of "$tree")"
    if [ -n "$bin" ]; then
        check_launcher "$label" "$target" "$tree" "$bin"
        check_emulators "$label" "$target" "$tree" "${T_REQ_EMU[$i]}"
    fi
    check_extensions "$label" "$target" "$tree"
done

echo "== $passes passed, $fails failed (lock $(basename "$LOCK"))"
[ "$fails" -eq 0 ]
