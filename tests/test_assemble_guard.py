#!/usr/bin/env python3
"""tools/assemble_guard.py: stop after two failed runs with the same inputs. Run: python3 tests/test_assemble_guard.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import assemble_guard  # noqa: E402


def run(i, conclusion, key="K1"):
    return {"id": i, "conclusion": conclusion, "key": key}


def check(key, runs):
    steps = {r["id"]: ["Set up job", "Inputs " + r["key"]] for r in runs}
    return assemble_guard.decide(key, runs, lambda rid: steps[rid])


class GuardTest(unittest.TestCase):
    def test_two_failures_stop(self):
        stop, failed = check("K1", [run(3, "failure"), run(2, "failure"), run(1, "success")])
        self.assertTrue(stop)
        self.assertEqual(failed, [3, 2])

    def test_one_failure_goes(self):
        self.assertFalse(check("K1", [run(2, "failure"), run(1, "success")])[0])

    def test_success_between_clears(self):
        self.assertFalse(check("K1", [run(3, "failure"), run(2, "success"), run(1, "failure")])[0])

    def test_other_inputs_ignored(self):
        runs = [run(3, "failure", "K2"), run(2, "failure"), run(1, "failure", "K2")]
        self.assertFalse(check("K1", runs)[0])
        self.assertFalse(check("K3", runs)[0])

    def test_cancelled_does_not_count_or_clear(self):
        stop, _ = check("K1", [run(3, "failure"), run(2, "cancelled"), run(1, "failure")])
        self.assertTrue(stop)

    def test_run_without_marker_step(self):
        runs = [run(2, "failure"), run(1, "failure")]
        self.assertFalse(assemble_guard.decide("K1", runs, lambda rid: ["Set up job"])[0])

    def test_no_runs(self):
        self.assertEqual(check("K1", []), (False, []))


if __name__ == "__main__":
    unittest.main()
