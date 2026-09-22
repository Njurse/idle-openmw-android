#!/usr/bin/env python3
"""Tests for tools/android/ui-overhaul.py.

Run:  python tools/android/tests/test_ui_overhaul.py

NOTE: build fixtures with chr(13)/chr(10) rather than writing "\\r\\n" literals
in a shell heredoc. Bash heredocs in this workspace mangle backslash escapes
before Python ever sees them, so a heredoc-written test cannot detect the
damage it caused.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from importlib import import_module  # noqa: E402

ui = import_module('ui-overhaul')  # the module name has a hyphen

LF = chr(10)
CRLF = chr(13) + chr(10)

# A trimmed but structurally faithful copy of the engine's dialogue layout.
DIALOGUE = (
    '<?xml version="1.0" encoding="UTF-8"?>' + LF +
    LF +
    '<MyGUI type="Layout">' + LF +
    '    <Widget type="Window" skin="MW_Window" layer="Windows" '
    'position="0 0 588 433" name="_Main">' + LF +
    '        <Property key="MinSize" value="380 230"/>' + LF +
    '        <Widget type="Widget" skin="MW_Box" position="8 8 381 381" align="Stretch"/>' + LF +
    '    </Widget>' + LF +
    '</MyGUI>' + LF
)

# One that already carries an align attribute, and a self-closing root tag.
WITH_ALIGN = ('<MyGUI type="Layout">' + LF +
              '  <Widget type="Window" position="10 20 400 300" '
              'align="Left Top" name="_Main"/>' + LF +
              '</MyGUI>' + LF)

NO_ROOT = ('<MyGUI type="Layout">' + LF +
           '  <Widget type="Widget" name="Something"/>' + LF + '</MyGUI>' + LF)


class TestRootWidget(unittest.TestCase):
    def test_finds_the_main_widget(self):
        widget, _ = ui.find_root_widget(DIALOGUE)
        self.assertIn('name="_Main"', widget)
        self.assertIn('type="Window"', widget)

    def test_reads_the_position(self):
        self.assertEqual(ui.root_position(DIALOGUE), '0 0 588 433')

    def test_refuses_a_layout_it_cannot_understand(self):
        # must not guess -- a wrong rewrite of an engine file is invisible
        with self.assertRaises(ui.LayoutError):
            ui.find_root_widget(NO_ROOT)

    def test_handles_a_self_closing_root(self):
        self.assertEqual(ui.root_position(WITH_ALIGN), '10 20 400 300')


class TestBandPosition(unittest.TestCase):
    SCREEN = (1080, 2340)

    def test_bottom_band_starts_below_the_game_view(self):
        # 0.55 * 2340 = 1287
        self.assertEqual(
            ui.band_position('0 0 588 433', ui.BOTTOM_BAND, self.SCREEN),
            '0 1287 588 433')

    def test_top_band_keeps_the_window_at_the_top(self):
        self.assertEqual(
            ui.band_position('0 0 588 433', ui.TOP_BAND, self.SCREEN),
            '0 0 588 433')

    def test_height_is_clamped_to_the_band(self):
        # a 1200px-tall window cannot fit in a 1053px band
        result = ui.band_position('0 0 400 1200', ui.BOTTOM_BAND, self.SCREEN)
        self.assertEqual(result, '0 1287 400 1053')

    def test_width_is_left_alone(self):
        # squashing the authored width would break each window's internals
        result = ui.band_position('0 0 588 433', ui.BOTTOM_BAND, self.SCREEN)
        self.assertEqual(result.split()[2], '588')

    def test_rejects_a_malformed_position(self):
        with self.assertRaises(ui.LayoutError):
            ui.band_position('0 0 588', ui.BOTTOM_BAND, self.SCREEN)


class TestApplyRule(unittest.TestCase):
    SCREEN = (1080, 2340)
    RULE = ui.Rule(ui.BOTTOM_BAND, 'Left Bottom HStretch', 'test')

    def test_rewrites_position_and_align(self):
        new, old = ui.apply_rule(DIALOGUE, self.RULE, self.SCREEN)
        self.assertEqual(old, '0 0 588 433')
        self.assertIn('position="0 1287 588 433"', new)
        self.assertIn('align="Left Bottom HStretch"', new)

    def test_preserves_everything_else_byte_for_byte(self):
        # this is the whole point: engine updates to the rest of the window
        # must still apply, so nothing but the root tag may change
        new, _ = ui.apply_rule(DIALOGUE, self.RULE, self.SCREEN)
        for keep in ('<?xml version="1.0" encoding="UTF-8"?>',
                     '<Property key="MinSize" value="380 230"/>',
                     '<Widget type="Widget" skin="MW_Box" position="8 8 381 381"',
                     '</MyGUI>'):
            self.assertIn(keep, new)
        # only the root line differs
        self.assertEqual(len(new.splitlines()), len(DIALOGUE.splitlines()))
        differing = [i for i, (a, b) in
                     enumerate(zip(new.splitlines(), DIALOGUE.splitlines())) if a != b]
        self.assertEqual(len(differing), 1, msg=f'lines differing: {differing}')

    def test_replaces_an_existing_align(self):
        new, _ = ui.apply_rule(WITH_ALIGN, self.RULE, self.SCREEN)
        self.assertIn('align="Left Bottom HStretch"', new)
        self.assertNotIn('align="Left Top"', new)

    def test_a_crlf_file_stays_crlf(self):
        # Regression: Path.read_text()/write_text() apply universal newline
        # translation, which rewrote every line of the CRLF engine file and made
        # the override differ on all 63 lines instead of exactly one.
        crlf = DIALOGUE.replace(LF, CRLF)
        new, _ = ui.apply_rule(crlf, self.RULE, self.SCREEN)
        self.assertTrue(ui.has_crlf(new))
        self.assertEqual(new.count(CRLF), crlf.count(CRLF))
        self.assertEqual(new.count(LF), new.count(CRLF))  # no bare LF introduced

    def test_is_idempotent(self):
        once, _ = ui.apply_rule(DIALOGUE, self.RULE, self.SCREEN)
        twice, _ = ui.apply_rule(once, self.RULE, self.SCREEN)
        self.assertEqual(once, twice)


class TestRun(unittest.TestCase):
    def make_install(self, root: Path, names: list[str], newline: str = LF) -> Path:
        mygui = root / 'resources' / 'mygui'
        mygui.mkdir(parents=True)
        for name in names:
            body = DIALOGUE.replace(LF, newline)
            (mygui / name).write_bytes(body.encode('utf-8'))
        return root

    def test_writes_overrides_for_present_layouts(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            install = self.make_install(tmp_path / 'install',
                                        ['openmw_inventory_window.layout'])
            out = tmp_path / 'mod'
            report = ui.run(install, out, (1080, 2340))
            self.assertTrue((out / 'mygui' / 'openmw_inventory_window.layout').is_file())
            self.assertTrue(any(r.startswith('WRITE') for r in report))

    def test_bytes_survive_a_round_trip(self):
        # the file on disk must keep CRLF and change exactly one body line
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            install = self.make_install(tmp_path / 'install',
                                        ['openmw_journal.layout'], newline=CRLF)
            ui.run(install, tmp_path / 'mod', (1080, 2340))
            out = (tmp_path / 'mod' / 'mygui' / 'openmw_journal.layout').read_bytes()
            body = out.split(b'-->' + CRLF.encode(), 1)[1]
            self.assertEqual(body.count(CRLF.encode()), DIALOGUE.count(LF))
            self.assertIn(b'position="0 1287 588 433"', body)
            self.assertNotIn(b'\n\n', body.replace(CRLF.encode(), b''))

    def test_reports_a_missing_layout_instead_of_failing(self):
        # An install that has layouts, but not the ones we target, is an
        # engine-version difference -- report it, do not fail.
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            install = self.make_install(tmp_path / 'install', ['openmw_unrelated.layout'])
            report = ui.run(install, tmp_path / 'mod', (1080, 2340))
            self.assertTrue(report)
            self.assertTrue(all(r.startswith('SKIP') for r in report),
                            msg=f'unexpected: {report}')

    def test_generated_file_carries_a_provenance_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            install = self.make_install(tmp_path / 'install', ['openmw_journal.layout'])
            ui.run(install, tmp_path / 'mod', (1080, 2340))
            text = (tmp_path / 'mod' / 'mygui' / 'openmw_journal.layout').read_bytes()
            self.assertIn(b'generated by tools/android/ui-overhaul.py', text)
            self.assertIn(b'openmw_journal.layout', text)

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            install = self.make_install(tmp_path / 'install', ['openmw_journal.layout'])
            ui.run(install, tmp_path / 'mod', (1080, 2340), dry_run=True)
            self.assertFalse((tmp_path / 'mod').exists())

    def test_no_layouts_at_all_is_an_error(self):
        # an empty directory means the --install path is wrong: fail loudly
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                ui.run(Path(tmp), Path(tmp) / 'mod', (1080, 2340))


class TestRuleSet(unittest.TestCase):
    def test_every_rule_has_a_sane_band(self):
        for name, rule in ui.RULES.items():
            lo, hi = rule.band
            self.assertLess(lo, hi, name)
            self.assertGreaterEqual(lo, 0.0, name)
            self.assertLessEqual(hi, 1.0, name)

    def test_every_rule_stretches_the_width(self):
        # on a narrow screen a fixed-width window is the main thing that breaks
        for name, rule in ui.RULES.items():
            self.assertIn('HStretch', rule.align, name)

    def test_the_named_windows_are_covered(self):
        for wanted in ('openmw_dialogue_window.layout',
                       'openmw_inventory_window.layout',
                       'openmw_trade_window.layout',
                       'openmw_container_window.layout'):
            self.assertIn(wanted, ui.RULES)


if __name__ == '__main__':
    unittest.main(verbosity=2)
