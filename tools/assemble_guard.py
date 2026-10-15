#!/usr/bin/env python3
"""assemble.yml's plan job: stop re-running a build that keeps failing for the same inputs.

Every run's plan job has a step named "Inputs <key>" (key = the components' fingerprint + the appliance sha),
so the jobs API tells which inputs a past run had. decide() looks at the completed runs, newest first, and
says "stop" when the last two runs with this key both failed (a success or a cancelled/skipped run in between
does not count as a failure; a success as the newest one clears it).

    assemble_guard.py --repo autobleem2/autobleem-appliance --key <key> --current-run <id>

prints "stop" or "go" on stdout (the reason on stderr); needs `gh` and GH_TOKEN. Tests: tests/test_assemble_guard.py
"""
import argparse
import json
import subprocess
import sys

LIMIT = 2          # failures in a row that stop the re-runs
MAX_RUNS = 20      # completed runs looked at (one jobs request each)
STEP_PREFIX = "Inputs "


def decide(key, runs, steps_of):
    """runs: completed runs, newest first ({"id", "conclusion"}); steps_of(id) -> the step names of its jobs.
    Returns (stop, failed_run_ids)."""
    failed = []
    for run in runs[:MAX_RUNS]:
        if run.get("conclusion") not in ("success", "failure"):
            continue
        if STEP_PREFIX + key not in steps_of(run["id"]):
            continue
        if run["conclusion"] == "success":
            break
        failed.append(run["id"])
        if len(failed) >= LIMIT:
            break
    return len(failed) >= LIMIT, failed


def gh_json(path):
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--current-run", default="")
    a = ap.parse_args()
    try:
        data = gh_json(f"repos/{a.repo}/actions/workflows/assemble.yml/runs?per_page=30&status=completed")
        runs = [r for r in data.get("workflow_runs", []) if str(r["id"]) != a.current_run]
        runs.sort(key=lambda r: r.get("created_at", ""), reverse=True)

        def steps_of(rid):
            jobs = gh_json(f"repos/{a.repo}/actions/runs/{rid}/jobs?per_page=100").get("jobs", [])
            return [s["name"] for j in jobs for s in j.get("steps", [])]

        stop, failed = decide(a.key, runs, steps_of)
    except Exception as e:  # the guard must never be what breaks a build
        print(f"guard unavailable ({e}); building", file=sys.stderr)
        stop, failed = False, []
    if stop:
        print("the last runs with these inputs failed: " + " ".join(str(i) for i in failed), file=sys.stderr)
    print("stop" if stop else "go")


if __name__ == "__main__":
    main()
