#!/usr/bin/env python3
"""Merge a freshly-filled rpi_imager_repo.json (one architecture's placeholders filled in by
make_rpi_image.sh) with whatever is already published at the same version's site path (the other
architecture's own fill-in). Each per-arch build starts from the raw template (tools/rpi_imager_repo.json)
and only fills its own os_list entry, leaving the other one as untouched __PLACEHOLDER__ tokens - publishing
that as-is overwrites the other architecture's already-published entry, reverting it to raw placeholders
(found live on the site, 2026-09-23: armhf and arm64 flip-flopped between correct and placeholder-broken
depending on which architecture published last).

    merge_rpi_imager_json.py FRESH EXISTING_OR_MISSING OUT

FRESH is this run's own filled copy (build_image/out/rpi_imager_repo.json). EXISTING_OR_MISSING is the
currently-published copy at the site's rpi-imager/images/<version>/rpi_imager_repo.json - may not exist yet
(the first architecture to publish a given version). OUT is where the merged result is written, ready for
repo_publish.sh. Per os_list entry (matched by "name"): keep FRESH's entry if it has no placeholder fields
of its own (this run's architecture); otherwise take EXISTING's entry for that name if it is itself
fully filled in, so a placeholder is only ever kept as a last resort (neither side has filled it yet).
"""
import json
import sys


def is_placeholder(value):
    return isinstance(value, str) and value.startswith("__") and value.endswith("__")


def is_filled(entry):
    return not any(is_placeholder(v) for v in entry.values())


def main():
    fresh_path, existing_path, out_path = sys.argv[1:4]
    with open(fresh_path) as f:
        fresh = json.load(f)
    try:
        with open(existing_path) as f:
            existing = json.load(f)
    except FileNotFoundError:
        existing = None

    existing_by_name = {o["name"]: o for o in (existing or {}).get("os_list", [])}
    merged_list = []
    for entry in fresh["os_list"]:
        name = entry["name"]
        if is_filled(entry):
            merged_list.append(entry)
        elif name in existing_by_name and is_filled(existing_by_name[name]):
            merged_list.append(existing_by_name[name])
        else:
            merged_list.append(entry)  # neither side has it yet - keep the placeholder, visibly so

    merged = dict(fresh)
    merged["os_list"] = merged_list
    with open(out_path, "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
