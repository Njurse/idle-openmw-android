"""Unit tests for tools/android/gamedata.py (pure logic; no game install needed).

Run:  python -m unittest discover -s tools/android/tests -v
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import gamedata  # noqa: E402


def make_install(root: Path, names=gamedata.REQUIRED_FILES, data_name="Data Files",
                 ini: bool = True, ini_name: str = "Morrowind.ini") -> Path:
    """Build a fake Morrowind install with the given files.

    The root gets a Morrowind.ini because OpenMW-Android requires one beside
    "Data Files" -- an install without it is not selectable on a device.
    """
    install = root / "Morrowind"
    data = install / data_name
    data.mkdir(parents=True, exist_ok=True)
    for index, name in enumerate(names):
        (data / name).write_bytes(b"x" * (index + 1))
    if ini:
        (install / ini_name).write_text("[Game Files]\nGameFile0=Morrowind.esm\n", encoding="utf-8")
    return install


class DataDirTest(unittest.TestCase):
    def test_finds_the_steam_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            self.assertEqual(gamedata.data_dir_of(install), install / "Data Files")

    def test_tolerates_alternative_folder_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp), data_name="DataFiles")
            self.assertEqual(gamedata.data_dir_of(install), install / "DataFiles")

    def test_none_for_an_empty_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(gamedata.data_dir_of(Path(tmp)))
        self.assertIsNone(gamedata.data_dir_of(None))


class LooksLikeMorrowindTest(unittest.TestCase):
    def test_true_for_a_populated_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(gamedata.looks_like_morrowind(make_install(Path(tmp))))

    def test_false_when_the_master_file_is_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            # a Data Files folder with only archives is not a usable install
            install = make_install(Path(tmp), names=("Morrowind.bsa",))
            self.assertFalse(gamedata.looks_like_morrowind(install))


class ValidateTest(unittest.TestCase):
    def test_complete_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            report = gamedata.validate(gamedata.data_dir_of(install))
            self.assertTrue(report["ok"])
            self.assertEqual(report["missing"], [])
            self.assertEqual(len(report["found"]), len(gamedata.REQUIRED_FILES))
            # sizes are summed from the real files
            self.assertEqual(report["total_bytes"], sum(range(1, len(gamedata.REQUIRED_FILES) + 1)))

    def test_reports_every_missing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp), names=("Morrowind.esm",))
            report = gamedata.validate(gamedata.data_dir_of(install))
            self.assertFalse(report["ok"])
            self.assertIn("Bloodmoon.esm", report["missing"])
            self.assertIn("Morrowind.bsa", report["missing"])
            self.assertNotIn("Morrowind.esm", report["missing"])


class FindInstallTest(unittest.TestCase):
    def test_explicit_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            self.assertEqual(gamedata.find_install(explicit=str(install)), install)

    def test_explicit_data_files_dir_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            found = gamedata.find_install(explicit=str(install / "Data Files"))
            self.assertEqual(found, install)

    def test_explicit_wrong_path_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(gamedata.find_install(explicit=tmp))

    def test_scans_extra_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_install(Path(tmp))
            found = gamedata.find_install(extra_roots=[Path(tmp)])
            self.assertEqual(found, Path(tmp) / "Morrowind")

    def test_none_when_nothing_is_installed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(gamedata.find_install(extra_roots=[Path(tmp)]))


class SteamLibraryTest(unittest.TestCase):
    def test_parses_extra_library_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            steam = Path(tmp) / "Steam"
            (steam / "steamapps").mkdir(parents=True)
            (steam / "steamapps" / "libraryfolders.vdf").write_text(
                '"libraryfolders"\n{\n'
                '\t"0"\n\t{\n\t\t"path"\t"C:\\\\Program Files (x86)\\\\Steam"\n\t}\n'
                '\t"1"\n\t{\n\t\t"path"\t"F:\\\\SteamLibrary"\n\t}\n'
                "}\n",
                encoding="utf-8",
            )
            roots = gamedata.steam_library_roots(steam)
            # the Steam root itself comes first, then whatever the VDF adds
            self.assertEqual(roots[0], steam)
            self.assertIn(Path("F:/SteamLibrary"), roots)
            self.assertIn(Path(r"C:/Program Files (x86)/Steam"), roots)

    def test_parsed_roots_are_deduplicated(self):
        with tempfile.TemporaryDirectory() as tmp:
            steam = Path(tmp) / "Steam"
            (steam / "steamapps").mkdir(parents=True)
            # libraryfolders.vdf normally names the canonical Steam dir as entry 0
            (steam / "steamapps" / "libraryfolders.vdf").write_text(
                '"libraryfolders"\n{\n'
                '\t"1"\n\t{\n\t\t"path"\t"F:\\\\SteamLibrary"\n\t}\n'
                '\t"2"\n\t{\n\t\t"path"\t"F:\\\\SteamLibrary"\n\t}\n'
                "}\n",
                encoding="utf-8",
            )
            roots = gamedata.steam_library_roots(steam)
            self.assertEqual(roots.count(Path("F:/SteamLibrary")), 1)

    def test_missing_steam_dir_is_not_an_error(self):
        self.assertEqual(gamedata.steam_library_roots(Path("nope")), [])


class ValidateInstallTest(unittest.TestCase):
    """The check OpenMW-Android performs, and whose failure reads
    "Error locating data files" on the device."""

    def test_ok_with_ini_and_data_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = gamedata.validate_install(make_install(Path(tmp)))
            self.assertTrue(report["ok"])
            self.assertEqual(report["missing"], [])
            self.assertIsNotNone(report["ini"])

    def test_missing_ini_is_reported_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = gamedata.validate_install(make_install(Path(tmp), ini=False))
            self.assertFalse(report["ok"])
            self.assertEqual(report["missing"][0], "Morrowind.ini")
            self.assertIsNone(report["ini"])

    def test_ini_match_is_case_insensitive(self):
        # the launcher matches case-insensitively (GameInstaller.findCaseInsensitive)
        with tempfile.TemporaryDirectory() as tmp:
            report = gamedata.validate_install(make_install(Path(tmp), ini_name="morrowind.INI"))
            self.assertTrue(report["ok"])

    def test_a_data_files_dir_without_an_ini_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp), ini=False)
            report = gamedata.validate_install(install / "Data Files")
            self.assertFalse(report["ok"])

    def test_find_root_file_is_case_insensitive(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp), ini_name="MORROWIND.ini")
            self.assertEqual(gamedata.find_root_file(install, "Morrowind.ini").name, "MORROWIND.ini")
            self.assertIsNone(gamedata.find_root_file(install, "nope") )


class OpenmwCfgTest(unittest.TestCase):
    def test_emits_both_data_dirs_and_content(self):
        cfg = gamedata.openmw_cfg_fragment(Path("C:/Games/Morrowind"))
        self.assertIn('data="C:/Games/Morrowind/Data Files"', cfg)
        self.assertIn('data="C:/Games/Morrowind/Mods/idle_openmw"', cfg)
        for name in gamedata.CONTENT_LOAD_ORDER:
            self.assertIn(f"content={name}", cfg)
        self.assertIn("content=idle_openmw.omwscripts", cfg)

    def test_backslashes_become_forward_slashes(self):
        cfg = gamedata.openmw_cfg_fragment(Path(r"C:\Games\Morrowind"))
        self.assertIn('data="C:/Games/Morrowind/Data Files"', cfg)

    def test_load_order_is_morrowind_then_official_expansions(self):
        self.assertEqual(gamedata.CONTENT_LOAD_ORDER,
                         ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"))


class ImportTest(unittest.TestCase):
    def test_plan_reproduces_the_device_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            staged = Path(tmp) / "staged"
            pairs = gamedata.plan_import(install, staged)
            # the ini at the root, the masters under "Data Files"
            self.assertEqual(len(pairs), len(gamedata.REQUIRED_FILES) + 1)
            self.assertIn((gamedata.find_root_file(install, "Morrowind.ini"),
                           staged / "Morrowind.ini"), pairs)
            self.assertTrue(all(
                dst.parent == staged / "Data Files"
                for src, dst in pairs if dst.name != "Morrowind.ini"))

    def test_plan_rejects_a_directory_without_data_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                gamedata.plan_import(Path(tmp), Path(tmp) / "staged")

    def test_import_copies_then_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            dest = Path(tmp) / "staged"
            expected = len(gamedata.REQUIRED_FILES) + 1

            first = gamedata.import_data(install, dest)
            self.assertEqual(len(first["copied"]), expected)
            self.assertEqual(first["skipped"], [])
            self.assertTrue((dest / "Morrowind.ini").is_file())
            self.assertTrue((dest / "Data Files" / "Morrowind.esm").is_file())

            second = gamedata.import_data(install, dest)
            self.assertEqual(second["copied"], [])
            self.assertEqual(len(second["skipped"]), expected)

    def test_import_redoes_a_truncated_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            dest = Path(tmp) / "staged"
            gamedata.import_data(install, dest)

            # simulate a half-finished copy from a previous run
            victim = dest / "Data Files" / "Morrowind.esm"
            victim.write_bytes(b"")

            again = gamedata.import_data(install, dest)
            self.assertIn("Morrowind.esm", again["copied"])
            self.assertEqual(victim.stat().st_size,
                             (gamedata.data_dir_of(install) / "Morrowind.esm").stat().st_size)


class ManifestTest(unittest.TestCase):
    def test_manifest_records_sizes_and_omits_hashes_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            manifest = gamedata.build_manifest(gamedata.data_dir_of(install))
            self.assertTrue(manifest["ok"])
            self.assertNotIn("sha256", manifest["files"][0])
            self.assertEqual(manifest["total_bytes"],
                             sum(range(1, len(gamedata.REQUIRED_FILES) + 1)))

    def test_manifest_can_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = make_install(Path(tmp))
            manifest = gamedata.build_manifest(gamedata.data_dir_of(install), hash_files=True)
            self.assertEqual(len(manifest["files"][0]["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
