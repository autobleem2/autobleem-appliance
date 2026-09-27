# AutoBleem Appliance — Package Assembly

This repository assembles the complete AutoBleem distribution for each target platform: the launcher, emulators, RetroArch, and extensions (PSC-Bios, the Store) into platform-specific packages and disk images.

## Packages by Target

**Console (PSC)** — `autobleem-appliance/assemble-psc.sh` builds the stick image: a FAT32 partition with the launcher, emulators, RetroArch, and bundled extensions. Artifacts from the launcher and pcsx-ab repositories are staged into the tree. **The English user manual PDF ships in `Docs/`** (D4's last part, 2026-09-27, the owner's call: English only, ~4.4 MB): `assemble-psc.sh` fetches `Docs/autobleem-user-manual-en.pdf` straight from the download site (`https://autobleem.retromenele.pl/manuals/autobleem-user-manual-en.pdf` — autobleem-manuals has no releases, its CI publishes there on every develop push) into the launcher's own `Docs/` next to its `README.txt` (which stays the pointer to the site for every other language). Not a `fetch_release_assets` call — a plain HTTPS `curl` with a `%PDF` + >1 MB sanity check; a failed or bad fetch fails the whole assemble (`AB_MANUAL_PDF_URL` overrides the URL, e.g. to prove the failure path).

**Raspberry Pi 32-bit and 64-bit** — `assemble.sh` stages the launcher, RetroArch, and system libraries into an installer package (`autobleem-rpi-*.tar.gz`, `autobleem-rpi64-*.tar.gz`). `install.sh` applies it to a working system, creating the partition layout and dropping the files into place. **PSC-Bios is now bundled** (2026-09-26): `assemble.sh` stages `console-tools-rpi-*.tar.gz` / `console-tools-rpi64-*.tar.gz` into `extensions/pscbios/`, which `install.sh` copies into the data partition's `Extensions/` on every install and update. The console tools carry the unified version (VERSION file, or AB_SOURCE_TAG for nightlies), fetched like the launcher.

**PC USB stick (32-bit)** — `assemble.sh` stages the launcher, RetroArch and libraries into `autobleem-pcusb-*.tar.gz`. **PSC-Bios is now bundled**: `console-tools-pcusb-*.tar.gz` staged into `extensions/pscbios/`, installed by `install.sh` into `Extensions/`.

**Windows** — `assemble-win.sh` builds an NSIS installer package and a portable .zip. No PSC-Bios (Windows has no Network & Controllers provider).

## Local packaging (`tools/make_rpi_package.sh`)

A second, local-only route to a Pi/PC-stick tarball, for a developer with a fresh cross-build and no
tagged unified release to point `assemble.sh` at - it never touches GitHub releases except for the themes
(below). DOCS-5 (2026-09-27, `payload_linux/` moved here from the launcher): this repo owns
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

## Build order and CI

**Merge order constraint** (2026-09-26): the console-tools' new **linux job** (CI matrix building PSC-Bios for rpi, rpi64, pcusb) must merge into develop **first**, produce a nightly release, and have its artifacts available **before** the appliance change (commit 3b41376) merges. Otherwise `assemble.sh` fails looking for `console-tools-<key>-*.tar.gz`. The appliance CI does not need an assemble.yml / fingerprint change—the artifacts are already fetched by the workflows.

**Staging** (2026-09-26): `assemble.sh` calls `stage_console_tools_extension()` (new, in `tools/release_assets.sh`), which fetches the console-tools nightly from the GitHub release, stages `Extensions/pscbios/` into the package's own `extensions/pscbios/`, and validates the plugin via `check_extension_stamp` (renamed from `stage_extension`'s SDK check). The plugin must be built for the package's platform key (rpi/rpi64/pcusb) and, where the launcher's binary is available to read, carry the same SDK stamp as the launcher.
