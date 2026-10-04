#!/usr/bin/env bash
#
# EMU-24: payload_linux/install.sh and the save-state keys of RetroArch's retroarch.cfg (Pi / PC stick).
#
#   - a FRESH retroarch.cfg has savestate_auto_save, the thumbnail, the flat savestates/ folder (the same shape as the
#     console's) and the sorting off, and never savestate_auto_load (the launcher sets that per launch);
#   - an EXISTING cfg (an update) gets the keys set, its other lines stay, and its savestate_directory is not moved
#     (states already saved there would be left behind);
#   - running it twice changes nothing.
#
# The functions are extracted verbatim from install.sh (as test_update_keeps_processors.sh does).
#
# Run: tests/rc/test_retroarch_state_keys.sh [path-to-install.sh]
# Exit 0 = all hold.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"

[ -f "$INSTALL_SH" ] || { echo "FAIL: $INSTALL_SH not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FUNCS="$WORK/funcs.sh"
for fn in write_retroarch_config set_cfg_key write_retroarch_state_keys; do
    awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print; if (/^\}/) exit}' "$INSTALL_SH" >> "$FUNCS"
    grep -q "^$fn() {" "$FUNCS" || { echo "FAIL: could not extract $fn() from $INSTALL_SH"; exit 1; }
done
grep -q '^RA_SUBDIRS=.*savestates' "$INSTALL_SH" || { echo "FAIL: RA_SUBDIRS has no savestates"; exit 1; }

run_funcs() { # $1 = RA_ROOT, then the function names
    local root="$1"; shift
    bash -c '
        set -euo pipefail
        log() { :; }
        write_file() { cat > "$1"; }
        DRY_RUN=0
        RA_ROOT="$1"; shift
        . "$0"
        for f in "$@"; do "$f"; done
    ' "$FUNCS" "$root" "$@"
}

fail=0
check() { # description, command...
    local what="$1"; shift
    if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
}

# --- a fresh install ---
FRESH="$WORK/fresh"; mkdir -p "$FRESH"
run_funcs "$FRESH" write_retroarch_config write_retroarch_state_keys
cfg="$FRESH/retroarch.cfg"
check "fresh: auto save on" grep -qx 'savestate_auto_save = "true"' "$cfg"
check "fresh: thumbnail on" grep -qx 'savestate_thumbnail_enable = "true"' "$cfg"
check "fresh: flat savestates folder" grep -qx "savestate_directory = \"$FRESH/savestates\"" "$cfg"
check "fresh: no sorting by core" grep -qx 'sort_savestates_enable = "false"' "$cfg"
check "fresh: no auto load" bash -c "! grep -q savestate_auto_load '$cfg'"
check "fresh: each key once" bash -c "[ \$(grep -c '^savestate_auto_save' '$cfg') = 1 ]"

# --- an update of an older cfg ---
OLD="$WORK/old"; mkdir -p "$OLD"
printf 'savestate_directory = "%s/states"\nsavestate_auto_save = "false"\nvideo_smooth = "true"\n' "$OLD" > "$OLD/retroarch.cfg"
run_funcs "$OLD" write_retroarch_config write_retroarch_state_keys
cfg="$OLD/retroarch.cfg"
check "update: auto save set" grep -qx 'savestate_auto_save = "true"' "$cfg"
check "update: thumbnail added" grep -qx 'savestate_thumbnail_enable = "true"' "$cfg"
check "update: sorting off" grep -qx 'sort_savestates_enable = "false"' "$cfg"
check "update: the folder stays" grep -qx "savestate_directory = \"$OLD/states\"" "$cfg"
check "update: the user's other lines stay" grep -qx 'video_smooth = "true"' "$cfg"
cp "$cfg" "$WORK/once"
run_funcs "$OLD" write_retroarch_state_keys
check "update: a second run changes nothing" cmp -s "$cfg" "$WORK/once"

exit $fail
