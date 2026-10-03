# Release locks and the package check

A release is built from exact components. `release/<version>.lock` names them; `tools/check_release.sh` proves the
built packages match it. (Wiring it into CI comes after alpha1.)

## The lock (`v2.0.0-alpha1.lock`)

Plain ini: `[section]` lines, `key = value` lines, `#` comment lines (never after a value). Greppable:
`grep -A4 '^\[emunxt\]' release/v2.0.0-alpha1.lock`.

| Section | Keys | Read by the check |
|---|---|---|
| `[release]` | `version`, `channel`, `sdk`, `targets`, `win_files` | version, channel, extension ABI |
| `[launcher]`, `[core]`, `[themes]`, `[libpicofe]` | `repo`, `branch`, `commit` | `launcher.commit` (the hash after the version) |
| `[emunxt]`, `[emu]` | `repo`, `commit`, `describe` | `describe` must be in the emulator binary - or, when it is an untagged `<tag>-<n>-g<commit>`, the release's own version (the promote tags that commit after the lock is written) |
| `[ext_store]`, `[pscbios]` | `repo`, `commit`, `version` | `version` = the extension's `extension.ini` |

## Running it

```
tools/check_release.sh release/v2.0.0-alpha1.lock <dist-dir>...
```

Needs bash 4, unzip, tar, grep, awk (the build image or plain Linux). Each `<dist-dir>` holds built packages: the
launcher's `dist/` (`psc/`, `pcusb/`, `rpi/`, `rpi64/`, `win/`), ext_store's `dist/`, console-tools' `dist/`, or the
appliance's output (`autobleem-{rpi-armhf,rpi-arm64,pcusb-i386}-*.tar.gz`). Packages are unpacked to a temp folder and
only read. One line per check - `PASS`, `FAIL` or `SKIP` (cannot be read from this package) - and the exit status is 1
when anything FAILs.

Checks, per launcher package: a `VERSION` file that is the lock's version (optionally followed by the launcher commit
hash); `BUILD.txt` the same, and its target; the launcher binary shows the lock's version; no `nightly`/`dirty` in a
prerelease/release package; the channel string; the launcher's SDK stamp (`sdk=<ABI>;...;target=<t>`). Emulators
(psc, win product): the `emunxt` and `emu` binaries contain the lock's `describe`. Extensions (every `bin/<t>/*.so|dll`
found): SDK stamp = the lock's ABI, target = the package's target, same stamp as the launcher of that target, and the
`extension.ini` version. The Windows installer's file name is checked for the version.

## What it cannot see

- **The channel**: the channel names sit in the launcher as the words it compares with, so the channel check proves
  only that the word is present, not which channel the build was given. (Proposal: `ci/build.sh` writes
  `channel` into `BUILD.txt`.)
- **UPX-packed launchers** (the psc one) hide their version, channel and stamp: only the `VERSION` file is checked.
- **Commits** of core, themes, libpicofe, ext_store and console-tools are not in any package; they are recorded for the
  builder. Emulator commits are checked through the describe string.
