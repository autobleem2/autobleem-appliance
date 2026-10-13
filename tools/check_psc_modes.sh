#!/usr/bin/env bash
# check_psc_modes.sh STAGE - fail if a program in the staged PSC tree lacks its executable bit.
# Looks at regular files under Autobleem/bin/autobleem, Autobleem/rc, Autobleem/bin/emu*, Autobleem/bin/abpad
# that are ELF binaries or start with '#!' (shared libraries, *.so*, are not run directly and are skipped).
# A stick formatted ext4 keeps the modes the package carries, so a 0644 program there cannot start.
set -uo pipefail

stage="${1:?usage: check_psc_modes.sh STAGE}"
bad=0
for dir in "$stage"/Autobleem/bin/autobleem "$stage"/Autobleem/rc "$stage"/Autobleem/bin/emu* "$stage"/Autobleem/bin/abpad; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
        case "$f" in *.so|*.so.*) continue ;; esac
        magic="$(head -c4 "$f" 2>/dev/null | od -An -c | tr -d ' ')"
        case "$magic" in
            '177ELF'|'#!'*) ;;
            *) continue ;;
        esac
        if [ ! -x "$f" ] || [ -n "$(find "$f" -maxdepth 0 ! -perm -u+x)" ]; then
            echo "missing the executable bit: ${f#"$stage"/}" >&2
            bad=1
        fi
    done < <(find "$dir" -type f -print0)
done
[ "$bad" = 0 ] || { echo "the staged tree has programs without u+x (add them to the chmod list in assemble-psc.sh)" >&2; exit 1; }
