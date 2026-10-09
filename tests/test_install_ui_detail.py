#!/usr/bin/env python3
"""The installer screen's detail line (bar 2: "n/total files - speed - done of sum MB"): the @@detail marker,
the fallback from ordinary output, and the text backend drawing it. Run: python3 tests/test_install_ui_detail.py"""
import importlib.util
import os
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
UI_PATH = os.path.join(ROOT, "payload_linux", "system", "autobleem-install-ui.py")
INSTALL_SH = os.path.join(ROOT, "payload_linux", "install.sh")

spec = importlib.util.spec_from_file_location("autobleem_install_ui", UI_PATH)
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def new_screen():
    return ui.Screen(None, None, None, None)


class DetailMarker(unittest.TestCase):
    def test_marker_sets_detail(self):
        s = new_screen()
        ui.feed(s, "@@detail 12/694 files - 3.2 MB/s - 41 of 205 MB", False)
        self.assertEqual(s.detail, "12/694 files - 3.2 MB/s - 41 of 205 MB")
        self.assertEqual(s.lines, [])               # not shown in the output box
        self.assertIsNone(s.transient)

    def test_phase_clears_detail(self):
        s = new_screen()
        ui.feed(s, "@@detail 1/2 files - 0.0 MB/s - 0 of 9 MB", False)
        ui.feed(s, "@@phase 3/8 Downloading", False)
        self.assertEqual(s.detail, "")
        self.assertFalse(s.detail_marked)
        self.assertEqual(s.phase, "Downloading")

    def test_marker_wins_over_fallback(self):
        s = new_screen()
        ui.feed(s, "@@detail 5/10 files - 1.0 MB/s - 4 of 80 MB", False)
        ui.feed(s, "[  6/ 10]  60% scph5501.bin", True)
        self.assertEqual(s.detail, "5/10 files - 1.0 MB/s - 4 of 80 MB")


class DetailFallback(unittest.TestCase):
    def test_counter(self):
        self.assertEqual(ui.fallback_detail("    [ 12/694]   1% scph5501.bin"), "12/694 files")

    def test_wget_speed(self):
        self.assertEqual(ui.fallback_detail("retroarch.deb  62%[===>   ] 21.5MB  12.3MB/s"), "12.3 MB/s")
        self.assertEqual(ui.fallback_detail("x.png  10%[>  ] 3K  512K/s"), "512 KB/s")

    def test_both(self):
        self.assertEqual(ui.fallback_detail("[ 3/9] 33% a.bin 1.5MB/s"), "3/9 files - 1.5 MB/s")

    def test_plain_line_has_none(self):
        self.assertEqual(ui.fallback_detail("Installing the launcher"), "")

    def test_feed_uses_fallback(self):
        s = new_screen()
        ui.feed(s, "    [ 12/694]   1% scph5501.bin", True)
        self.assertEqual(s.detail, "12/694 files")
        self.assertEqual(s.percent, 1)


class Shorten(unittest.TestCase):
    def test_short_name_kept(self):
        self.assertEqual(ui.shorten("a.bin", 20), "a.bin")

    def test_long_name_keeps_both_ends(self):
        out = ui.shorten("a_very_long_file_name_here.bin", 14)
        self.assertEqual(len(out), 14)
        self.assertTrue(out.endswith(".bin"))
        self.assertIn("..", out)

    def test_no_room(self):
        self.assertEqual(ui.shorten("abc", 0), "")


class TextRender(unittest.TestCase):
    def rows(self, screen):
        be = ui.TextBackend(None, size=(100, 30))
        be.draw_progress(screen)
        return ["".join(ch for ch, _ in row) for row in be.cells]

    def test_detail_on_the_step_line(self):
        s = new_screen()
        ui.feed(s, "@@phase 3/8 Downloading", False)
        ui.feed(s, "[ 12/694]  2% scph5501.bin", True)
        ui.feed(s, "@@detail 12/694 files - 3.2 MB/s - 41 of 205 MB", False)
        rows = self.rows(s)
        hits = [r for r in rows if "12/694 files - 3.2 MB/s - 41 of 205 MB" in r]
        self.assertEqual(len(hits), 1)
        self.assertIn("This step", hits[0])
        self.assertLess(hits[0].index("This step"), hits[0].index("12/694"))

    def test_no_detail_no_line(self):
        s = new_screen()
        self.assertFalse([r for r in self.rows(s) if "files -" in r])

    def test_long_detail_is_cut_to_the_window(self):
        s = new_screen()
        ui.feed(s, "@@detail " + "x" * 300, False)
        for r in self.rows(s):
            self.assertEqual(len(r), 100)


class InstallScriptMarker(unittest.TestCase):
    def test_detail_only_with_the_marker_flag(self):
        with open(INSTALL_SH, encoding="utf-8") as f:
            text = f.read()
        start = text.index("bios_detail_loop \"$entries_file\"")
        guard = text.rindex("AB_UI_MARKERS", 0, start)
        self.assertLess(start - guard, 400)         # the loop is started right under the AB_UI_MARKERS test
        self.assertIn('@@detail %d/%d files - %.1f MB/s - %d of %d MB', text)


if __name__ == "__main__":
    unittest.main()
