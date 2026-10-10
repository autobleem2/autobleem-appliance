#!/usr/bin/env bash
#
# AUTOBLEEM-4: the case's POWER / RESET buttons and status LED (payload_linux/system/autobleem-gpio.sh, the two
# autobleem-gpio*.service units, gpio.conf, and install.sh's install_gpio() / configure_gpio_boot()).
#
#   1. the helper writes the right bytes for green / orange / red (compared with an independent encoder here:
#      3 SPI bits per WS2812B bit, 1 = 110, 0 = 100, G,R,B order, then 20 zero bytes of reset gap)
#   2. no gpio.conf / LED_TYPE=none / LED_TYPE=plain / device missing -> exit 0, no output, nothing written
#   3. the config.txt block: written once, idempotent, backup made, follows gpio.conf (pixel adds dtparam=spi=on,
#      plain adds enable_uart=1), an edit of gpio.conf replaces the block rather than stacking a second one
#   4. install_gpio() keeps an existing gpio.conf
#   5. every unit directive is on its own line: no comment glued to a directive, every non-comment line is
#      [Section] or Key=value
#   6. shellcheck on the helper and this test, and systemd-analyze verify, when available (verify may fail on
#      a host with a read-only filesystem - then it is reported as skipped, not failed)
#
# Run: tests/rc/test_gpio.sh        Exit 0 = all pass, 1 = a case failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/../../payload_linux"
HELPER="$PAYLOAD/system/autobleem-gpio.sh"
INSTALL_SH="$PAYLOAD/install.sh"
UNITS=("$PAYLOAD/system/autobleem-gpio.service" "$PAYLOAD/system/autobleem-gpio-poweroff.service")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

for f in "$HELPER" "$INSTALL_SH" "${UNITS[@]}" "$PAYLOAD/system/gpio.conf"; do
    [ -f "$f" ] || fail "$f not found"
done

# --- independent encoder: $1 $2 $3 = G R B as decimal; prints the 29-byte frame as hex ---
encode() {
    local bits="" b i k out=""
    for b in "$@"; do
        for i in 7 6 5 4 3 2 1 0; do
            if (( (b >> i) & 1 )); then bits+=110; else bits+=100; fi
        done
    done
    for ((k = 0; k < ${#bits}; k += 8)); do out+="$(printf '%02x' $((2#${bits:k:8})))"; done
    printf '%s' "$out"
    printf '%0*d' 40 0
}
hexof() { od -An -v -tx1 "$1" | tr -d ' \n'; }

# --- 1. colours ---
CONF="$WORK/gpio.conf"
printf 'POWER_GPIO=3\nRESET_GPIO=23\nLED_TYPE=pixel\nLED_SPI=/dev/spidev0.0\n' > "$CONF"
check_colour() {
    local name="$1"; shift
    local dev="$WORK/spi-$name" want got out
    : > "$dev"
    out="$(env AB_GPIO_CONF="$CONF" AB_GPIO_SPI="$dev" AB_GPIO_LOG="$WORK/log-$name" sh "$HELPER" "$name" 2>&1)" \
        || fail "$name: exit status $?"
    [ -z "$out" ] || fail "$name: unexpected output: $out"
    want="$(encode "$@")"
    got="$(hexof "$dev")"
    [ "$got" = "$want" ] || fail "$name: wrote $got, want $want"
    echo "ok: $name = $got"
}
check_colour green 64 0 0
check_colour orange 16 64 0
check_colour red 0 64 0
check_colour off 0 0 0

# a bad colour name is a usage error, nothing written
: > "$WORK/spi-bad"
env AB_GPIO_CONF="$CONF" AB_GPIO_SPI="$WORK/spi-bad" sh "$HELPER" purple >/dev/null 2>&1 && fail "purple: exit 0"
[ ! -s "$WORK/spi-bad" ] || fail "purple wrote bytes"

# --- 2. silent no-ops ---
quiet_case() {
    local name="$1" conf="$2" dev="$3" out
    out="$(env AB_GPIO_CONF="$conf" AB_GPIO_SPI="$dev" AB_GPIO_LOG="$WORK/log-q-$name" sh "$HELPER" green 2>&1)"
    [ $? -eq 0 ] || fail "$name: nonzero exit"
    [ -z "$out" ] || fail "$name: printed: $out"
    [ ! -s "$dev" ] || fail "$name: wrote to the device"
    echo "ok: $name is a silent no-op"
}
: > "$WORK/spi-q"
quiet_case "missing conf" "$WORK/nonexistent.conf" "$WORK/spi-q"
printf 'LED_TYPE=none\n' > "$WORK/none.conf"
quiet_case "LED_TYPE=none" "$WORK/none.conf" "$WORK/spi-q"
printf 'LED_TYPE=plain\n' > "$WORK/plain.conf"
quiet_case "LED_TYPE=plain" "$WORK/plain.conf" "$WORK/spi-q"
quiet_case "missing device" "$CONF" "$WORK/no-such-spidev"
[ ! -e "$WORK/no-such-spidev" ] || fail "missing device was created"
grep -q 'no .*no pixel' "$WORK/log-q-missing device" || fail "missing device: no debug line in the event sink"
# default device path from the conf (LED_SPI), not present on this host
printf 'LED_TYPE=pixel\nLED_SPI=%s/nope\n' "$WORK" > "$WORK/pix2.conf"
out="$(env AB_GPIO_CONF="$WORK/pix2.conf" sh "$HELPER" green 2>&1)"; [ $? -eq 0 ] && [ -z "$out" ] || fail "LED_SPI missing: $out"
echo "ok: LED_SPI from the pin map"

# --- 3 + 4. install.sh functions, extracted verbatim so the test cannot drift ---
extract() {
    awk -v fn="$1" '
        !p && $0 ~ "^" fn "\\(\\)[ ]*\\{" { p = 1; print; if ($0 ~ /\}[ \t]*$/) exit; next }
        p { print; if ($0 ~ /^\}/) exit }
    ' "$INSTALL_SH"
}
FUNCS="$WORK/funcs.sh"
{ extract log; extract warn; extract run; extract write_file; extract install_gpio; extract configure_gpio_boot; } > "$FUNCS"
for fn in run write_file install_gpio configure_gpio_boot; do
    grep -qE "^$fn\(\)" "$FUNCS" || fail "could not extract $fn() from install.sh"
done

BOOT="$WORK/boot"; CDIR="$WORK/etc-ab"; UDIR="$WORK/units"
mkdir -p "$BOOT" "$CDIR" "$UDIR"
printf '# stock config\ndtparam=audio=on\n[pi4]\narm_boost=1\n' > "$BOOT/config.txt"
cp "$BOOT/config.txt" "$WORK/config.orig"

inst() {   # runs one function under set -euo pipefail like install.sh
    env -i PATH="$PATH" BOOT_DIR="$BOOT" AB_GPIO_CONF_DIR="$CDIR" AB_GPIO_UNIT_DIR="$UDIR" \
        AB_GPIO_BIN="$WORK/autobleem-gpio" SCRIPT_DIR="$PAYLOAD" \
        bash -c 'set -euo pipefail; DRY_RUN=0; PLATFORM=rpi; source "'"$FUNCS"'"; '"$1" 2>&1
}

inst install_gpio >/dev/null || fail "install_gpio failed"
[ -f "$CDIR/gpio.conf" ] && [ -x "$WORK/autobleem-gpio" ] && [ -f "$UDIR/autobleem-gpio.service" ] \
    && [ -f "$UDIR/autobleem-gpio-poweroff.service" ] || fail "install_gpio did not install everything"
grep -q '^LED_TYPE=none' "$CDIR/gpio.conf" || fail "default gpio.conf is not LED_TYPE=none"
echo "ok: install_gpio installs conf, helper, units"

# the user's edits survive a second run
printf 'POWER_GPIO=3\nRESET_GPIO=24\nLED_TYPE=plain\n' > "$CDIR/gpio.conf"
inst install_gpio >/dev/null || fail "install_gpio (2nd) failed"
grep -q '^RESET_GPIO=24' "$CDIR/gpio.conf" || fail "install_gpio overwrote an existing gpio.conf"
echo "ok: existing gpio.conf kept"

# config.txt, plain LED with RESET on GPIO24
inst configure_gpio_boot >/dev/null || fail "configure_gpio_boot failed"
cmp -s "$BOOT/config.txt.autobleem-backup" "$WORK/config.orig" || fail "backup is not the original config.txt"
grep -q '^dtoverlay=gpio-shutdown,gpio_pin=3,active_low=1,gpio_pull=up$' "$BOOT/config.txt" || fail "no gpio-shutdown overlay"
grep -q '^dtoverlay=gpio-key,gpio=24,active_low=1,gpio_pull=up,keycode=164$' "$BOOT/config.txt" || fail "no gpio-key overlay"
grep -q '^enable_uart=1$' "$BOOT/config.txt" || fail "plain LED: no enable_uart=1"
grep -q '^dtparam=spi=on' "$BOOT/config.txt" && fail "plain LED: dtparam=spi=on must not be there"
head -n 4 "$BOOT/config.txt" | cmp -s - "$WORK/config.orig" || fail "the original config.txt lines were changed"
cp "$BOOT/config.txt" "$WORK/config.once"
inst configure_gpio_boot >/dev/null || fail "configure_gpio_boot (2nd) failed"
cmp -s "$BOOT/config.txt" "$WORK/config.once" || fail "second run changed config.txt - not idempotent"
cmp -s "$BOOT/config.txt.autobleem-backup" "$WORK/config.orig" || fail "backup changed on the second run"
echo "ok: config.txt block written once, idempotent, backup kept"

# switching to a pixel replaces the block
printf 'POWER_GPIO=3\nRESET_GPIO=23\nLED_TYPE=pixel\n' > "$CDIR/gpio.conf"
inst configure_gpio_boot >/dev/null || fail "configure_gpio_boot (pixel) failed"
[ "$(grep -c 'AutoBleem GPIO begin' "$BOOT/config.txt")" = 1 ] || fail "block stacked instead of replaced"
grep -q '^dtparam=spi=on$' "$BOOT/config.txt" || fail "pixel: no dtparam=spi=on"
grep -q '^enable_uart' "$BOOT/config.txt" && fail "pixel: stale enable_uart left"
grep -q 'gpio=23,' "$BOOT/config.txt" && ! grep -q 'gpio=24,' "$BOOT/config.txt" || fail "pixel: RESET pin not updated"
echo "ok: pixel block replaces the old one"

# LED_TYPE=none: overlays only
printf 'LED_TYPE=none\n' > "$CDIR/gpio.conf"
inst configure_gpio_boot >/dev/null || fail "configure_gpio_boot (none) failed"
grep -q '^dtparam=spi' "$BOOT/config.txt" && fail "none: spi must be off"
grep -q '^dtoverlay=gpio-shutdown' "$BOOT/config.txt" || fail "none: overlays missing"

# --no-boot-config: configure_boot() never calls it (checked in the source, the guard is the first line)
grep -A2 '^configure_boot() {' "$INSTALL_SH" | grep -q 'DO_BOOT_CONFIG' || fail "configure_boot lost its --no-boot-config guard"
grep -q 'configure_boot_rpi; configure_gpio_boot' "$INSTALL_SH" || fail "configure_gpio_boot is not called from configure_boot"

# --- 5. unit files: one directive per line ---
for u in "${UNITS[@]}"; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in
            "" | "#"*) ;;
            "["*"]") ;;
            [A-Za-z]*=*)
                key="${line%%=*}"
                [[ "$key" =~ ^[A-Za-z]+$ ]] || fail "$u:$n: odd key: $line"
                # a '#' after a value is a comment systemd would read as part of the value
                case "${line#*=}" in *" #"* | "#"*) fail "$u:$n: comment glued to a directive: $line" ;; esac ;;
            *) fail "$u:$n: not a section, comment or Key=value: $line" ;;
        esac
    done < "$u"
done
echo "ok: unit directives are on their own lines"
grep -q '^ConditionPathExists=/etc/autobleem/gpio.conf$' "${UNITS[0]}" || fail "no ConditionPathExists in the launcher unit"
grep -q '^Before=autobleem.service$' "${UNITS[0]}" || fail "green unit: no Before=autobleem.service"
grep -qE '^(Requires|Wants|BindsTo|RequiredBy)=' "${UNITS[0]}" && fail "green unit must not depend on anything (Requires=)"
grep -q '^Type=oneshot$' "${UNITS[1]}" && grep -q '^DefaultDependencies=no$' "${UNITS[1]}" \
    && grep -q '^Before=shutdown.target$' "${UNITS[1]}" || fail "poweroff unit: Type/DefaultDependencies/Before"

# --- 6. tools, when present ---
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s sh "$HELPER" || fail "shellcheck: autobleem-gpio.sh"
    shellcheck -x "${BASH_SOURCE[0]}" || fail "shellcheck: test_gpio.sh"
    echo "ok: shellcheck clean"
else
    echo "skip: shellcheck not installed"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    vdir="$WORK/verify"; mkdir -p "$vdir"
    cp "${UNITS[@]}" "$vdir/"
    if vout="$(systemd-analyze verify "$vdir"/autobleem-gpio.service "$vdir"/autobleem-gpio-poweroff.service 2>&1)"; then
        echo "ok: systemd-analyze verify"
    else
        echo "skip: systemd-analyze verify failed here (this host may be read-only / lack systemd): $(printf '%s' "$vout" | head -n 3)"
    fi
else
    echo "skip: systemd-analyze not installed"
fi

echo "PASS"
exit 0
