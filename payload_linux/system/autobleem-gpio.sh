#!/bin/sh
#
# autobleem-gpio - the status colour of the case's RGB pixel (AUTOBLEEM-4). Installed as
# /usr/local/bin/autobleem-gpio; run by autobleem-gpio.service (green, before the launcher starts) and
# autobleem-gpio-poweroff.service (orange, on the way down). `autobleem-gpio red` is the optional error
# state for anything that wants it (nothing calls it yet).
#
#   autobleem-gpio green|orange|red|off
#
# The buttons need no software at all: POWER is `dtoverlay=gpio-shutdown` and RESET a `dtoverlay=gpio-key`
# in config.txt (install.sh writes both), and the plain LED is GPIO14/TXD with enable_uart=1. This helper is
# only for LED_TYPE=pixel in /etc/autobleem/gpio.conf: one WS2812B on GPIO10 (SPI0 MOSI, pin 19).
#
# Nothing wired = silent no-op: with no gpio.conf, LED_TYPE other than "pixel", or no SPI device, it exits 0
# at once with no output. A missing device is logged at debug level only (never above, so a Pi without the
# pixel keeps a clean journal).
#
# How the pixel is driven, with printf and dd only: a WS2812B bit is a 1.25 us pulse, high for ~0.4 us (0)
# or ~0.8 us (1). Each WS bit is sent as 3 SPI bits at 2.4 MHz (417 ns each): 0 = 100, 1 = 110. A pixel is
# 3 colour bytes in G,R,B order = 24 WS bits = 72 SPI bits = 9 bytes; 20 zero bytes after it hold MOSI low
# for ~65 us, the latch/reset gap. The strings below are prebuilt (brightness 0x40 of 0xFF, a status light
# next to a screen should not glare):
#     green  G=40 R=00 B=00     orange G=10 R=40 B=00     red  G=00 R=40 B=00
#
# SPI SPEED - the one thing this script cannot do with printf/dd: the bytes are only right at ~2.4 MHz
# (anything from about 2.4 to 3.2 MHz is within the WS2812B's tolerance). The speed a plain write() uses is
# the spidev node's max_speed_hz from the device tree, not necessarily that. If `spi-config` (package
# spi-tools) is installed this sets it first (LED_SPI_HZ, default 2400000; spidev keeps it across opens).
# On some Pi 3/4 the SPI clock is derived from the core clock, which the firmware scales with the load, so
# the speed drifts and the colours flicker or come out wrong: pin it in config.txt with core_freq_min=500
# (Pi 4) or core_freq=250 (Pi 3) if so. This is not written by default.
#
# Environment (for the host test; production uses the defaults):
#   AB_GPIO_CONF   the pin map, default /etc/autobleem/gpio.conf
#   AB_GPIO_SPI    the SPI device, overrides LED_SPI from the pin map
#   AB_GPIO_LOG    a file to append the debug lines to instead of syslog (the event sink)

CONF="${AB_GPIO_CONF:-/etc/autobleem/gpio.conf}"

debug() {
    if [ -n "${AB_GPIO_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$AB_GPIO_LOG"
    elif command -v logger >/dev/null 2>&1; then
        logger -p daemon.debug -t autobleem-gpio -- "$*" 2>/dev/null
    fi
    return 0
}

[ -f "$CONF" ] || exit 0

LED_TYPE=none
LED_SPI=/dev/spidev0.0
LED_SPI_HZ=2400000
# shellcheck source=/dev/null
. "$CONF"
[ "$LED_TYPE" = pixel ] || exit 0

DEV="${AB_GPIO_SPI:-$LED_SPI}"
[ -e "$DEV" ] || { debug "no $DEV, no pixel"; exit 0; }

# 9 colour bytes + 20 bytes of reset gap
RESET='\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
case "${1:-}" in
    green)  PIXEL='\232\111\044\222\111\044\222\111\044' ;;
    orange) PIXEL='\222\151\044\232\111\044\222\111\044' ;;
    red)    PIXEL='\222\111\044\232\111\044\222\111\044' ;;
    off)    PIXEL='\222\111\044\222\111\044\222\111\044' ;;
    *) echo "usage: autobleem-gpio green|orange|red|off" >&2; exit 2 ;;
esac

if command -v spi-config >/dev/null 2>&1 && [ -c "$DEV" ]; then
    spi-config -d "$DEV" -s "$LED_SPI_HZ" >/dev/null 2>&1 || debug "spi-config failed on $DEV"
fi

# one write() of the whole frame: a split frame would latch half a colour
# shellcheck disable=SC2059
if ! printf "$PIXEL$RESET" | dd of="$DEV" bs=29 count=1 iflag=fullblock 2>/dev/null; then
    echo "autobleem-gpio: cannot write $DEV" >&2
    exit 1
fi
debug "$1 on $DEV"
exit 0
