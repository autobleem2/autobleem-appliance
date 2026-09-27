#!/usr/bin/env bash
#
# TOOLS-10 part (b): payload_linux/install.sh's unblock_bluetooth() under `set -euo pipefail`.
#
# The bug: the owner's Pi 400 had Bluetooth soft-blocked by rfkill, and systemd-rfkill restores that block
# at every boot from its saved state (/var/lib/systemd/rfkill/<device>:bluetooth, "1" = blocked) - a live
# `rfkill unblock` alone would not survive the next boot. unblock_bluetooth() (install.sh, run once at
# install, from both autobleem-firstboot.sh's fresh-image path and a hand-run install.sh on an existing
# system) unblocks live AND corrects any existing systemd-rfkill save file to "0", so the very next boot
# stays unblocked regardless of when systemd-rfkill itself would otherwise save.
#
# This exercises three cases against the real function body, extracted verbatim so the test cannot drift
# from what install.sh actually does (same idea as test_pkg_first_available.sh):
#   1. No rfkill on PATH at all (a PC stick, a VM without it) - must not fail, must not touch anything.
#   2. rfkill present but `rfkill list bluetooth` finds no adapter - must not fail, must not call unblock.
#   3. rfkill present with an adapter - must call `rfkill unblock bluetooth`, and must rewrite every
#      existing "*:bluetooth" save file under RFKILL_STATE_DIR to "0" (the test points that env var at a
#      temp dir - see install.sh's own comment on unblock_bluetooth for why it is overridable).
# In every case the function must return 0 (best-effort, `set -euo pipefail` must never abort on it) and
# must log a line either way.
#
# Run: tests/rc/test_unblock_bluetooth.sh [path-to-install.sh]
# Exit 0 = all three cases behave as above. Exit 1 = a case failed - see stderr/stdout for which.
# Needs bash on PATH (MSYS2 UCRT64 on Windows); skips (exit 0) with a note when there is none.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"

if ! command -v bash >/dev/null 2>&1; then
    echo "SKIP: no bash on PATH"
    exit 0
fi

if [ ! -f "$INSTALL_SH" ]; then
    echo "FAIL: $INSTALL_SH not found"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- extract unblock_bluetooth(), and the small helpers it calls (run, write_file, log, warn), verbatim
# from install.sh - a hand copy could quietly drift from the real functions. ---
extract() {
    # Matches both a one-liner ("log()  { printf ...; }") and a multi-line function ("run() {" / body / "}"),
    # since install.sh's own helpers use both styles.
    awk -v fn="$1" '
        !p && $0 ~ "^" fn "\\(\\)[ ]*\\{" {
            p = 1
            print
            if ($0 ~ /\}[ \t]*$/) exit
            next
        }
        p {
            print
            if ($0 ~ /^\}/) exit
        }
    ' "$INSTALL_SH"
}
FUNC_FILE="$WORK/funcs.sh"
{
    extract log
    extract warn
    extract run
    extract write_file
    extract unblock_bluetooth
} > "$FUNC_FILE"
for fn in log run write_file unblock_bluetooth; do
    if ! grep -qE "^$fn\(\)[ ]*\{" "$FUNC_FILE"; then
        echo "FAIL: could not extract $fn() from $INSTALL_SH"
        exit 1
    fi
done

mkdir -p "$WORK/bin" "$WORK/state"

# --- fake rfkill: "list bluetooth" prints an adapter line only when FAKE_HAS_BT=1 (empty output
# otherwise, as real rfkill does for a type with no matching device); "unblock bluetooth" just records
# that it ran, into FAKE_UNBLOCK_LOG. ---
cat > "$WORK/bin/rfkill" <<'RFKILL'
#!/usr/bin/env bash
if [ "$1 $2" = "list bluetooth" ]; then
    if [ "${FAKE_HAS_BT:-0}" = 1 ]; then
        printf '0: hci0: Bluetooth\n\tSoft blocked: yes\n\tHard blocked: no\n'
    fi
    exit 0
fi
if [ "$1 $2" = "unblock bluetooth" ]; then
    echo unblocked >> "${FAKE_UNBLOCK_LOG:?}"
    exit 0
fi
exit 1
RFKILL
chmod +x "$WORK/bin/rfkill"

# $1 = name, $2 = PATH to give the subshell (with or without $WORK/bin), remaining args = VAR=val pairs
# to set before running unblock_bluetooth. Prints the combined stdout+stderr on success; exits the whole
# test with FAIL if unblock_bluetooth does not return 0 (it must be best-effort under set -euo pipefail).
run_case() {
    local name="$1" case_path="$2" out status
    shift 2
    out="$(env -i PATH="$case_path" "$@" bash -c '
        set -euo pipefail
        DRY_RUN=0
        source "'"$FUNC_FILE"'"
        unblock_bluetooth
    ' 2>&1)"
    status=$?
    echo "--- case: $name ---"
    echo "$out"
    echo "exit status: $status"
    if [ "$status" -ne 0 ]; then
        echo "FAIL ($name): unblock_bluetooth aborted (exit $status) - not best-effort under set -e"
        exit 1
    fi
    printf '%s' "$out"
}

# 1. no rfkill at all: an empty bin dir on PATH (plus the real PATH for bash itself and other tools the
# function might call - the real PATH has no rfkill of its own on the dev host) so `command -v rfkill` fails
mkdir -p "$WORK/nobin"
out1="$(run_case "no rfkill" "$WORK/nobin:$PATH")"
case "$out1" in
    *"No rfkill"*) : ;;
    *) echo "FAIL (no rfkill): expected a 'No rfkill' log line, got: $out1"; exit 1 ;;
esac

# 2. rfkill present, no Bluetooth adapter
rm -f "$WORK/unblock.log"
out2="$(run_case "no adapter" "$WORK/bin:$PATH" FAKE_HAS_BT=0 FAKE_UNBLOCK_LOG="$WORK/unblock.log")"
case "$out2" in
    *"No Bluetooth adapter"*) : ;;
    *) echo "FAIL (no adapter): expected a 'No Bluetooth adapter' log line, got: $out2"; exit 1 ;;
esac
if [ -f "$WORK/unblock.log" ]; then
    echo "FAIL (no adapter): rfkill unblock was called when there is no adapter"
    exit 1
fi

# 3. rfkill present with an adapter, and an existing systemd-rfkill save file for it (as if a previous
# blocked boot had saved state) - must call unblock AND rewrite the save file to "0".
rm -f "$WORK/unblock.log"
STATE_DIR="$WORK/state/rfkill-3"
mkdir -p "$STATE_DIR"
printf '1\n' > "$STATE_DIR/platform-soc-amba-fe201000.serial:bluetooth"
out3="$(run_case "adapter present" "$WORK/bin:$PATH" FAKE_HAS_BT=1 FAKE_UNBLOCK_LOG="$WORK/unblock.log" RFKILL_STATE_DIR="$STATE_DIR")"
case "$out3" in
    *"Bluetooth unblocked"*) : ;;
    *) echo "FAIL (adapter present): expected a 'Bluetooth unblocked' log line, got: $out3"; exit 1 ;;
esac
if [ ! -f "$WORK/unblock.log" ]; then
    echo "FAIL (adapter present): rfkill unblock bluetooth was never called"
    exit 1
fi
saved="$(cat "$STATE_DIR/platform-soc-amba-fe201000.serial:bluetooth")"
if [ "$saved" != "0" ]; then
    echo "FAIL (adapter present): the systemd-rfkill save file still says '$saved', want '0' - the unblock would not survive a reboot"
    exit 1
fi

echo "PASS"
exit 0
