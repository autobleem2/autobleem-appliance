#!/usr/bin/env bash
#
# UIREV-51: payload_linux/install.sh brings the package's default theme to an installation that did not have it
# (the theme setting switches once), and leaves an installation that already had the folder on the user's choice.
# package_default_theme() and set_config_theme() are extracted verbatim from install.sh and run on temp trees;
# install_payload()'s own wiring is covered by the VM walk (an update over a stick, then the launcher's shot).
#
# Run: tests/rc/test_default_theme_update.sh [path-to-install.sh]
# Exit 0 = all cases pass. Needs bash on PATH; skips (exit 0) when there is none.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"

command -v bash >/dev/null 2>&1 || { echo "SKIP: no bash on PATH"; exit 0; }
[ -f "$INSTALL_SH" ] || { echo "FAIL: $INSTALL_SH not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FUNCS="$WORK/funcs.sh"
: > "$FUNCS"
for fn in package_default_theme set_config_theme; do
    awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" {p=1} p {print; if (/^\}/) exit}' "$INSTALL_SH" >> "$FUNCS"
done
grep -q '^package_default_theme() {' "$FUNCS" && grep -q '^set_config_theme() {' "$FUNCS" ||
    { echo "FAIL: could not extract the functions from $INSTALL_SH"; exit 1; }

FAILS=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (expected '$2', got '$3')"
        FAILS=$((FAILS + 1))
    fi
}

# the install_payload() decision, as install.sh makes it: default theme of the package, was the folder there before,
# then the switch after the kept config.ini is back
update_case() { # update_case <data dir> <stage dir>
    local data="$1" stage="$2"
    bash -c '
        set -euo pipefail
        run() { "$@"; }
        STAGE_DIR="$2"
        source "'"$FUNCS"'"
        app_dest="$1/Autobleem/bin/autobleem"
        had=0
        default_theme="$(package_default_theme)"
        if [ -n "$default_theme" ] && [ -d "$1/Themes/$default_theme" ]; then had=1; fi
        if [ -n "$default_theme" ] && [ "$had" -eq 0 ] && [ -f "$app_dest/config.ini" ]; then
            set_config_theme "$app_dest/config.ini" "$default_theme"
        fi
    ' bash "$data" "$stage"
}

mkstage() { # mkstage <dir> <theme in config.ini> <folders under Themes/...>
    local d="$1" cfgtheme="$2"
    shift 2
    mkdir -p "$d/Autobleem/bin/autobleem" "$d/Themes"
    printf '[AutoBleem]\r\nAspect=false\r\nTheme=%s\r\nLanguage=English\r\n' "$cfgtheme" > "$d/Autobleem/bin/autobleem/config.ini"
    for t in "$@"; do mkdir -p "$d/Themes/$t"; done
}
mkdata() { # mkdata <dir> <config.ini text> <theme folders...>
    local d="$1" cfg="$2"
    shift 2
    mkdir -p "$d/Autobleem/bin/autobleem" "$d/Themes"
    printf '%b' "$cfg" > "$d/Autobleem/bin/autobleem/config.ini"
    for t in "$@"; do mkdir -p "$d/Themes/$t"; done
}
theme_of() { sed -n 's/^[Tt]heme=//p' "$1/Autobleem/bin/autobleem/config.ini" | head -1 | tr -d '\r'; }

# the package's default is what its own config.ini names, when it ships that folder
mkstage "$WORK/s1" ab2.0.0 ab2.0.0 default
check "package default theme = config.ini's Theme= when shipped" "ab2.0.0" "$(STAGE_DIR="$WORK/s1" bash -c "source '$FUNCS'; package_default_theme")"
mkstage "$WORK/s2" ab2.0.0 default
check "package default theme empty when the folder is not shipped" "" "$(STAGE_DIR="$WORK/s2" bash -c "source '$FUNCS'; package_default_theme")"

# new theme -> switched (the key replaced, the other settings kept)
mkdata "$WORK/d1" '[AutoBleem]\nTheme=aergb\nLanguage=Polish\n' ab2 aergb
update_case "$WORK/d1" "$WORK/s1"
check "new theme -> switched" "ab2.0.0" "$(theme_of "$WORK/d1")"
check "the other settings are kept" "Language=Polish" "$(grep '^Language=' "$WORK/d1/Autobleem/bin/autobleem/config.ini")"

# theme already there -> kept
mkdata "$WORK/d2" '[AutoBleem]\nTheme=aergb\n' ab2 aergb ab2.0.0
update_case "$WORK/d2" "$WORK/s1"
check "theme already there -> kept" "aergb" "$(theme_of "$WORK/d2")"

# a config.ini without a Theme key -> the key added
mkdata "$WORK/d3" '[AutoBleem]\nLanguage=Polish\n' ab2
update_case "$WORK/d3" "$WORK/s1"
check "no Theme key -> added" "ab2.0.0" "$(theme_of "$WORK/d3")"

# a package that does not ship the default -> nothing switched
mkdata "$WORK/d4" '[AutoBleem]\nTheme=aergb\n' ab2
update_case "$WORK/d4" "$WORK/s2"
check "package without the default folder -> kept" "aergb" "$(theme_of "$WORK/d4")"

# an old stick's lower-case key (AutoBleem 1.0 wrote theme=) is replaced, not doubled
mkdata "$WORK/d5" 'theme=aergb\n' ab2
update_case "$WORK/d5" "$WORK/s1"
check "1.0 style config.ini -> switched" "ab2.0.0" "$(theme_of "$WORK/d5")"
check "and only one Theme key" "1" "$(grep -ci '^theme=' "$WORK/d5/Autobleem/bin/autobleem/config.ini")"

[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failed"; exit 1; }
