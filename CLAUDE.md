# AutoBleem Appliance — Package Assembly

This repository assembles the complete AutoBleem distribution for each target platform: the launcher, emulators, RetroArch, and extensions (PSC-Bios, the Store) into platform-specific packages and disk images.

## Packages by Target

**Console (PSC)** — `autobleem-appliance/assemble-psc.sh` builds the stick image: a FAT32 partition with the launcher, emulators, RetroArch, and bundled extensions. Artifacts from the launcher and pcsx-ab repositories are staged into the tree. **The English user manual PDF ships in `Docs/`** (D4's last part, 2026-09-27, the owner's call: English only, ~4.4 MB): `assemble-psc.sh` fetches `Docs/autobleem-user-manual-en.pdf` straight from the download site (`https://autobleem.retromenele.pl/manuals/autobleem-user-manual-en.pdf` — autobleem-manuals has no releases, its CI publishes there on every develop push) into the launcher's own `Docs/` next to its `README.txt` (which stays the pointer to the site for every other language). Not a `fetch_release_assets` call — a plain HTTPS `curl` with a `%PDF` + >1 MB sanity check; a failed or bad fetch fails the whole assemble (`AB_MANUAL_PDF_URL` overrides the URL, e.g. to prove the failure path).

**The PSC as two zips (PLATFORM-21, the owner)** — `assemble-psc.sh` step 6 runs `tools/psc_zips.py` over the finished `autobleem-psc-<v>.tar.gz` and writes `autobleem-psc-<v>-base.zip` (the stick's file system plus the three cover databases, no `RetroArch/`) and `autobleem-psc-<v>-full.zip` (the same plus everything AutoBleemInstaller gives a stick with RetroArch ticked, laid out as `installer_job.cpp`'s `retroarch()` does: `RetroArch/` with the site's `psc/retroarch` zip and `psc/cores` pack, a `retroarch.cfg`, libretro's bundles from `buildbot.libretro.com/assets/frontend` (assets, autoconfig, database-rdb, database-cursors, cheats, overlays, shaders_glsl), the AutoBleem 2 theme over `assets/` (each stock file it replaces kept as `.prab2`), empty `bios/` with a README and `roms/`; the `psc/apps` pack at the root and the `psc/libs` pack in `Autobleem/lib/`, links skipped and the packs' catalog files left out). If the installer's retroarch() changes, `psc_zips.py` follows it. **Neither zip has a BIOS file**: `psc_zips.py` reads the finished zips back and fails the build on a known BIOS name, a `.bin/.rom/.bios` that is not on its short allow-list `OWN_PATTERNS` (the stick's own `LUPDATA.BIN`, Prince of Persia's and OpenTyrian's data, RetroArch's rgui fonts), any file in a `bios` folder but its README, or a name the site's `psc/bios/biospack.txt` lists; the workflow repeats the check (`--check`) as its own step before the upload. A new legitimate `.bin` on the stick = add it to `OWN_PATTERNS` in `psc_zips.py`. Tests: `python3 tests/test_psc_zips.py`. Both zips ride the PSC artifact into `publish-release` (a nightly, a preview or a v* release) like the other `.zip` files; the Windows installer, the tarball and the online update path are unchanged.

**Raspberry Pi 32-bit and 64-bit** — `assemble.sh` stages the launcher, RetroArch, and system libraries into an installer package (`autobleem-rpi-*.tar.gz`, `autobleem-rpi64-*.tar.gz`). `install.sh` applies it to a working system, creating the partition layout and dropping the files into place. **PSC-Bios is now bundled** (2026-09-26): `assemble.sh` stages `console-tools-rpi-*.tar.gz` / `console-tools-rpi64-*.tar.gz` into `extensions/pscbios/`, which `install.sh` copies into the data partition's `Extensions/` on every install and update. The console tools carry the unified version (VERSION file, or AB_SOURCE_TAG for nightlies), fetched like the launcher.

**The Pi image's pre-install (PLATFORM-23, 2026-10-07)** — `tools/make_rpi_image.sh` (rootless, as root, with `proot` >= 5.5.0 and `qemu-user-static`; `--preinstall auto` falls back to the old injection-only build when they are missing) dumps the Lite image's ext4 root to a directory (`debugfs rdump` + `tools/rpi_rootfs.py fixmodes`, which restores the setuid/sticky bits and hard links rdump drops), runs `apt-get install` of `install.sh --print-packages` (the single package list) under proot+qemu with no binfmt/privileges, installs the plymouth theme, rebuilds the initramfs of every kernel, and packs the directory back with `mke2fs -d` into a grown root partition (same label/UUID, base image's features, MBR entry resized). It also sets the quiet-splash `cmdline.txt` words and `disable_splash=1`, masks `getty@tty1` (no login prompt on the card's screen, the first boot's failure message stays on tty8) and, with `--retroarch-tarball/--cores-tarball` (or `--fetch-offline`), stages RetroArch + cores in `/opt/autobleem-image/offline` for `install.sh --offline`. `install.sh` skips apt for packages dpkg already has (`packages_present`), skips the initramfs when the theme is unchanged, and logs a timestamp per phase plus a table at the end. proot 5.4.x (Debian's package) does not translate `statx`, which qemu-user forwards: the build refuses it with a message. Tests: `python3 tests/test_rpi_rootfs.py`.

**PC USB stick (32-bit)** — `assemble.sh` stages the launcher, RetroArch and libraries into `autobleem-pcusb-*.tar.gz`. **PSC-Bios is now bundled**: `console-tools-pcusb-*.tar.gz` staged into `extensions/pscbios/`, installed by `install.sh` into `Extensions/`.

**Windows** — `assemble-win.sh` builds an NSIS installer package and a portable .zip. No PSC-Bios (Windows has no Network & Controllers provider).

## Local packaging (`tools/make_rpi_package.sh`)

A second, local-only route to a Pi/PC-stick tarball, for a developer with a fresh cross-build and no
tagged unified release to point `assemble.sh` at - it reads GitHub releases for the themes (below) and for the
emulators (next). DOCS-5 (2026-09-27, `payload_linux/` moved here from the launcher): this repo owns
`payload_linux/`, `tools/release_assets.sh` and this script; the launcher's own checkout (a separate
clone, `autobleem2/autobleem`) owns the cross-compiled binary, `src/resources/`, `LICENSE`/
`THIRD_PARTY_NOTICES.md` and the build's `version.h`. Run it from inside the launcher checkout, or set
`AB_LAUNCHER_DIR`:

    cd /path/to/autobleem && ./make_rpi.sh && \
      AB_LAUNCHER_DIR="$PWD" /path/to/autobleem-appliance/tools/make_rpi_package.sh

Themes come from `autobleem2/autobleem-themes`' own release via `tools/release_assets.sh`'s
`stage_themes()` (the same call `assemble.sh` makes) - needs `gh` authenticated. `AB_THEMES_DIR=<a local
autobleem-themes checkout>` is a fallback that copies `Themes/` straight from disk, for a machine with no
`gh` (or offline).

**Emulators**: the trees checked in under `payload_linux/Autobleem/bin/emu*` are never packaged (an old one
rolled devices back, 2026-10-01). `AB_EMU_CHANNEL=release|testing|nightly|preview` makes the script fetch pcsx-abnxt
(and pcsx-ab, frozen at its one release) of that channel from their GitHub releases (`stage_emulator` in
`tools/release_assets.sh`; `gh` or curl + python3): release = latest full release, testing = newest `v*`
pre-release, nightly = `nightly`, preview = `preview` (none: the nightly, with a loud line in the log). Not set: the
emulator `ci/build.sh` staged into `build_*/emu-stage/` from a local checkout, else the nightly. No emulator for the
channel = the build fails. `assemble.sh` (the CI route) already took them from the release of its channel.

## Build order and CI

**Merge order constraint** (2026-09-26): the console-tools' new **linux job** (CI matrix building PSC-Bios for rpi, rpi64, pcusb) must merge into develop **first**, produce a nightly release, and have its artifacts available **before** the appliance change (commit 3b41376) merges. Otherwise `assemble.sh` fails looking for `console-tools-<key>-*.tar.gz`. The appliance CI does not need an assemble.yml / fingerprint change—the artifacts are already fetched by the workflows.

**Staging** (2026-09-26): `assemble.sh` calls `stage_console_tools_extension()` (new, in `tools/release_assets.sh`), which fetches the console-tools nightly from the GitHub release, stages `Extensions/pscbios/` into the package's own `extensions/pscbios/`, and validates the plugin via `check_extension_stamp` (renamed from `stage_extension`'s SDK check). The plugin must be built for the package's platform key (rpi/rpi64/pcusb) and, where the launcher's binary is available to read, carry the same SDK stamp as the launcher.
