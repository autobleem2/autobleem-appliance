#!/usr/bin/env python3
"""Read a GitHub releases API answer on stdin and print one fact from it (tools/release_assets.sh's
stage_emulator uses this where there is no `gh` and no jq - the build laptop).

Each takes the JSON file as a last argument, else reads stdin.

  release_pick.py latest           releases/latest      -> its tag_name
  release_pick.py testing          releases (list)      -> the newest pre-release tagged v* (the testing channel)
  release_pick.py id               releases/tags/<tag>  -> its numeric id (the tag's own asset list can lag)
  release_pick.py assets <glob>    releases/<id>/assets -> "<asset api url> <tab> <asset name>" per matching name
"""
import fnmatch
import json
import sys


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    # the answer comes from the file named last (assets: after the glob), else stdin
    path = sys.argv[3] if mode == "assets" and len(sys.argv) > 3 else sys.argv[2] if mode != "assets" and len(sys.argv) > 2 else ""
    if path:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)
    if mode == "latest":
        print(data.get("tag_name", ""))
    elif mode == "id":
        print(data.get("id", ""))
    elif mode == "testing":
        # the API lists newest first
        for rel in data:
            tag = rel.get("tag_name", "")
            if rel.get("prerelease") and not rel.get("draft") and tag.startswith("v"):
                print(tag)
                break
    elif mode == "assets":
        pattern = sys.argv[2]
        for asset in data:
            if fnmatch.fnmatchcase(asset["name"], pattern):
                print("%s\t%s" % (asset["url"], asset["name"]))
    else:
        sys.exit("usage: release_pick.py latest|id|testing|assets <glob>")


if __name__ == "__main__":
    main()
