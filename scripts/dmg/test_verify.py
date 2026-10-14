"""Negative artifact checks; run with build/dmg-venv/bin/python -B scripts/dmg/test_verify.py."""
import contextlib
import io
import json
import plistlib
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias, TargetInfo, VolumeInfo

from build import load_layout
from verify import verify


def background_alias(filename, folder=".background"):
    # Synthetic HFS alias: mac_alias cannot encode the >32-bit CNIDs of an APFS
    # temporary directory. The real pipeline creates aliases on the mounted HFS DMG.
    date = datetime(2026, 1, 1, tzinfo=timezone.utc)
    volume = VolumeInfo("Zeus", date, b"H+", 0, 0, b"\0\0")
    target = TargetInfo(0, filename, 3, 4, date, b"\0" * 4, b"\0" * 4,
                        posix_path="/" + folder + "/" + filename)
    return Alias(volume=volume, target=target).to_bytes()


class InstallerVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zeus-release-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.layout_path = Path(__file__).with_name("layout.json")
        self.layout = load_layout(self.layout_path)
        contents = self.root / "Zeus.app/Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
        (self.root / "Applications").symlink_to("/Applications")
        (self.root / ".VolumeIcon.icns").write_bytes(b"test icon")
        (self.root / ".background").mkdir()
        background = self.root / ".background/background.tiff"
        background.write_bytes(b"test background")
        with DSStore.open(str(self.root / ".DS_Store"), "w+") as store:
            x, y = self.layout["window_origin"]
            w, h = self.layout["window_size"]
            store["."]["bwsp"] = {"ShowToolbar": False, "ShowSidebar": False, "ShowStatusBar": False,
                                  "ShowPathbar": False, "ShowTabView": False, "WindowBounds": f"{{{{{x}, {y}}}, {{{w}, {h}}}}}"}
            store["."]["icvl"] = ("type", b"icnv")
            store["."]["icvp"] = {"iconSize": 128, "arrangeBy": "none", "backgroundType": 2,
                                  "textSize": self.layout["text_size"], "labelOnBottom": True, "showIconPreview": False,
                                  "backgroundImageAlias": background_alias("background.tiff")}
            for name, xy in self.layout["icon_locations"].items():
                store[name]["Iloc"] = tuple(xy)

    def check(self, version="0.1.0"):
        with contextlib.redirect_stdout(io.StringIO()):
            verify(self.root, self.layout_path, version, "1")

    def test_valid_layout_reads_back(self):
        self.check()

    def test_wrong_icon_location_rejected(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            store["Zeus.app"]["Iloc"] = (99, 99)
        with self.assertRaisesRegex(ValueError, "Wrong position"):
            self.check()

    def test_sidebar_rejected(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            window = store["."]["bwsp"]
            window["ShowSidebar"] = True
            store["."]["bwsp"] = window
        with self.assertRaisesRegex(ValueError, "chrome visible"):
            self.check()

    def test_wrong_version_rejected(self):
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            self.check(version="9.9.9")

    def test_wrong_applications_target_rejected(self):
        link = self.root / "Applications"
        link.unlink()
        link.symlink_to("/tmp")
        with self.assertRaisesRegex(ValueError, "Applications link"):
            self.check()

    def test_wrong_background_alias_rejected(self):
        wrong = self.root / "background.tiff"
        wrong.write_bytes(b"wrong background")
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            view = store["."]["icvp"]
            view["backgroundImageAlias"] = background_alias("background.tiff", folder=".")
            store["."]["icvp"] = view
        with self.assertRaisesRegex(ValueError, "wrong background"):
            self.check()

    def test_layout_cannot_read_outside_art_directory(self):
        layout = {**self.layout, "background_1x": "../private.png"}
        path = self.root / "invalid-layout.json"
        path.write_text(json.dumps(layout))
        with self.assertRaisesRegex(ValueError, "relative to the art directory"):
            load_layout(path)

    def test_frame_cannot_crop_the_background_with_its_title_bar(self):
        layout = {**self.layout, "window_size": self.layout["content_size"]}
        path = self.root / "cropped-layout.json"
        path.write_text(json.dumps(layout))
        with self.assertRaisesRegex(ValueError, "plus the title bar"):
            load_layout(path)

    def test_label_size_cannot_overflow_the_designer_plinth(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            view = store["."]["icvp"]
            view["textSize"] = 14
            store["."]["icvp"] = view
        with self.assertRaisesRegex(ValueError, "label size"):
            self.check()


if __name__ == "__main__":
    unittest.main()
