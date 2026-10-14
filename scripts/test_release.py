#!/usr/bin/env python3
"""Release/appcast regressions using only disposable files and mocked commands."""
import base64
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import appcast
import release_support as release

ROOT = Path(__file__).resolve().parent.parent
KEY = base64.b64encode(bytes(32)).decode()
SIGNATURE = base64.b64encode(bytes(64)).decode()


def signed(length):
    return f'sparkle:edSignature="{SIGNATURE}" length="{length}"'


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="zeus-appcast-test-")
        self.addCleanup(self.directory.cleanup)
        self.feed = Path(self.directory.name) / "appcast.xml"

    def add(self, version="0.2.0", build="6", notes="<p>A &amp; B</p>"):
        return appcast.update_feed(self.feed, version, build,
            f"https://github.com/colinc86/zeus/releases/download/v{version}/Zeus-{version}.zip",
            signed(123), notes)

    def test_new_item_has_signed_public_zip_and_html(self):
        notes = "<p>Unicode: ⚡; CDATA: ]]></p>"
        self.assertTrue(self.add(notes=notes))
        _, _, items, _ = appcast.read_feed(self.feed)
        item = items[0]
        self.assertEqual(appcast.text(item, appcast.SPARKLE, "version"), "6")
        self.assertEqual(appcast.text(item, appcast.SPARKLE, "shortVersionString"), "0.2.0")
        self.assertEqual(appcast.text(item, appcast.SPARKLE, "minimumSystemVersion"), "26.0")
        enclosure = item.getElementsByTagName("enclosure")[0]
        self.assertEqual(enclosure.getAttribute("length"), "123")
        self.assertEqual(enclosure.getAttributeNS(appcast.SPARKLE, "edSignature"), SIGNATURE)
        description = item.getElementsByTagName("description")[0]
        html = "".join(node.data for node in description.childNodes)
        self.assertIn("CDATA: ]]>", html)
        self.assertIn("Unicode: ⚡", html)
        self.assertFalse(self.add(notes=notes))

    def test_rerun_is_byte_identical_but_conflicting_item_is_refused(self):
        self.add()
        before = self.feed.read_bytes()
        self.assertFalse(self.add())
        self.assertEqual(before, self.feed.read_bytes())
        with self.assertRaisesRegex(ValueError, "differs"):
            self.add(notes="changed")
        with self.assertRaises(ValueError):
            self.add(build="7")
        self.assertEqual(before, self.feed.read_bytes())

    def test_orders_by_numeric_build_and_preserves_historical_cdata(self):
        self.add(build="9")
        self.add(version="0.3.0", build="10")
        document, channel, items, _ = appcast.read_feed(self.feed)
        # A feed ordered incorrectly by hand must still compare against its max.
        channel.appendChild(items[0])
        self.feed.write_bytes(document.toxml(encoding="utf-8"))
        with self.assertRaises(ValueError):
            self.add(version="0.4.0", build="10")
        self.add(version="0.4.0", build="11")
        _, _, items, builds = appcast.read_feed(self.feed)
        self.assertEqual(builds, [11, 10, 9])
        self.assertEqual(len(items), 3)
        self.assertIn("A &amp; B", self.feed.read_text())

    def test_nonincreasing_builds_never_change_feed(self):
        self.add()
        before = self.feed.read_bytes()
        for build in ("5", "6", "0", "6.1", "invalid"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.add(version="0.3.0", build=build)
            self.assertEqual(self.feed.read_bytes(), before)

    def test_prerelease_is_listed_like_gloss_and_malformed_feed_is_not_overwritten(self):
        self.add(version="0.3.0-beta.2", build="7")
        _, _, items, _ = appcast.read_feed(self.feed)
        self.assertEqual(appcast.text(items[0], appcast.SPARKLE, "shortVersionString"), "0.3.0-beta.2")
        self.assertEqual(items[0].getElementsByTagNameNS(appcast.SPARKLE, "channel"), [])
        self.feed.write_text("broken XML")
        with self.assertRaises(Exception):
            self.add()
        self.assertEqual(self.feed.read_text(), "broken XML")

    def test_invalid_signature_or_nonpublic_url_never_creates_feed(self):
        for signature, url in ((signed(0), "https://github.com/colinc86/zeus/releases/download/v0.2.0/app.zip"),
                               (signed(1), "https://api.github.com/repos/colinc86/zeus/releases/assets/1")):
            with self.assertRaises(ValueError):
                appcast.update_feed(self.feed, "0.2.0", "6", url, signature, "<p>notes</p>")
            self.assertFalse(self.feed.exists())


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        printing = patch("release_support.print", create=True)
        printing.start(); self.addCleanup(printing.stop)
        self.directory = tempfile.TemporaryDirectory(prefix="zeus-release-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.artifacts = self.root / "build/release"
        self.artifacts.mkdir(parents=True)
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/appcast.py", self.root / "scripts/appcast.py")
        shutil.copy(ROOT / "scripts/release_support.py", self.root / "scripts/release_support.py")
        shutil.copy(ROOT / "scripts/release.sh", self.root / "scripts/release.sh")
        (self.root / "appcast.xml").write_text(appcast.HEADER)
        self.version = "0.2.0"
        self.project()
        self.notes = self.root / "build/notes.md"
        self.notes.write_text("# Zeus\n\nA useful update.\n")
        self.commands = []
        self.remote = None
        self.tag_exists = False
        self.committed = False
        self.fail_push = False
        self.wrong_download = False
        self.real_run = release.run

    def project(self):
        (self.root / "project.yml").write_text(f"targets:\n  Zeus:\n    settings:\n      base:\n        MARKETING_VERSION: '{self.version}'\n        CURRENT_PROJECT_VERSION: 6\n")

    def manifest(self, notarized=True):
        names = [f"Zeus-{self.version}.dmg", f"Zeus-{self.version}.zip"]
        for name in names:
            (self.artifacts / name).write_bytes(b"fixture signed artifact")
        data = {"version": self.version, "build": "6", "notarized": notarized, "commit": "abc123",
                "signature": signed((self.artifacts / names[1]).stat().st_size),
                "assets": {name: release.digest(self.artifacts / name) for name in names}}
        release.save_json(self.artifacts / "publish.json", data)

    def fake_run(self, arguments, *, cwd, input=None, check=True):
        args = [str(arg) for arg in arguments]
        self.commands.append(args)
        output, error, status = "", "", 0
        if args[0] == sys.executable:
            return self.real_run(args, cwd=cwd, input=input, check=check)
        if args[:3] == ["git", "branch", "--show-current"]:
            output = "main\n"
        elif args[:4] == ["git", "remote", "get-url", "origin"]:
            output = "https://github.com/colinc86/zeus.git\n"
        elif args[:3] == ["git", "rev-parse", "--verify"]:
            output, status = ("abc123\n", 0) if self.tag_exists else ("", 1)
        elif args[:2] == ["git", "tag"]:
            self.tag_exists = True
        elif args[:3] == ["git", "diff", "--quiet"]:
            status = 0 if self.committed else 1
        elif args[:2] == ["git", "commit"]:
            self.committed = True
        elif args == ["git", "push", "origin", "HEAD:refs/heads/main"] and self.fail_push:
            self.fail_push = False
            status = 1
        elif args[:2] == ["gh", "api"] and args[2].startswith("repos/"):
            if self.remote is None:
                status, error = 1, "HTTP 404: Not Found"
            else:
                output = json.dumps(self.remote)
        elif args[:3] == ["gh", "release", "create"]:
            assets = [{"name": path.name, "size": path.stat().st_size,
                       "browser_download_url": f"https://github.com/colinc86/zeus/releases/download/v{self.version}/{path.name}"}
                      for path in self.artifacts.glob("Zeus-*.*")]
            self.remote = {"tag_name": f"v{self.version}", "draft": False, "prerelease": "--prerelease" in args,
                           "body": self.notes.read_text(), "assets": assets}
        elif args[:3] == ["gh", "release", "upload"]:
            self.remote["assets"].extend({"name": Path(name).name, "size": Path(name).stat().st_size,
                "browser_download_url": f"https://github.com/colinc86/zeus/releases/download/v{self.version}/{Path(name).name}"}
                for name in args[4:args.index("--repo")])
        elif args[:3] == ["gh", "release", "download"]:
            name = args[args.index("--pattern") + 1]
            destination = Path(args[args.index("--dir") + 1]) / name
            shutil.copy(self.artifacts / name, destination)
            if self.wrong_download:
                destination.write_bytes(b"different archive")
        elif args[:3] == ["gh", "api", "markdown"]:
            self.assertEqual(json.loads(input)["text"], self.notes.read_text())
            output = "<h1>Zeus</h1><p>A useful update.</p>"
        elif args[0] not in ("git", "gh"):
            raise AssertionError(f"Unexpected command: {args}")
        if check and status:
            raise ValueError("fixture interrupted push")
        return subprocess.CompletedProcess(args, status, output, error)

    def test_project_yml_is_only_version_source_and_duplicates_fail(self):
        self.assertEqual(release.project_version(self.root / "project.yml"), ("0.2.0", "6"))
        with (self.root / "project.yml").open("a") as stream:
            stream.write("CURRENT_PROJECT_VERSION: 7\n")
        with self.assertRaisesRegex(ValueError, "exactly once"):
            release.project_version(self.root / "project.yml")

    def test_missing_sparkle_tools_are_reported_without_using_global_artifacts(self):
        with self.assertRaisesRegex(ValueError, "Sparkle tools missing"):
            release.sparkle_tools(self.root)

    def test_publish_then_resume_after_appcast_commit_push_failure(self):
        self.manifest()
        self.fail_push = True
        with patch.object(release, "run", self.fake_run):
            with self.assertRaisesRegex(ValueError, "interrupted"):
                release.publish(self.root, self.notes, resume=False)
            before = (self.root / "appcast.xml").read_bytes()
            release.publish(self.root, self.notes, resume=True)
        self.assertEqual((self.root / "appcast.xml").read_bytes(), before)
        self.assertEqual(sum(cmd[:3] == ["gh", "release", "create"] for cmd in self.commands), 1)
        self.assertEqual(sum(cmd[:2] == ["git", "tag"] for cmd in self.commands), 1)
        self.assertEqual(sum(cmd[:2] == ["git", "commit"] for cmd in self.commands), 1)

    def test_prerelease_and_resume_missing_asset(self):
        self.version = "0.3.0-beta.1"; self.project(); self.manifest()
        with patch.object(release, "run", self.fake_run):
            release.publish(self.root, self.notes, resume=False)
            self.remote["assets"] = [asset for asset in self.remote["assets"] if asset["name"].endswith(".dmg")]
            release.publish(self.root, self.notes, resume=True)
        create = next(cmd for cmd in self.commands if cmd[:3] == ["gh", "release", "create"])
        self.assertIn("--prerelease", create)
        uploads = [cmd for cmd in self.commands if cmd[:3] == ["gh", "release", "upload"]]
        self.assertEqual(len(uploads), 1)
        self.assertTrue(uploads[0][4].endswith(".zip"))
        self.assertNotIn("--clobber", uploads[0])

    def test_resume_after_tag_before_release(self):
        self.manifest(); self.tag_exists = True
        with patch.object(release, "run", self.fake_run):
            release.publish(self.root, self.notes, resume=True)
        self.assertFalse(any(cmd[:2] == ["git", "tag"] for cmd in self.commands))
        self.assertTrue(any(cmd[:3] == ["gh", "release", "create"] for cmd in self.commands))

    def test_modified_or_unnotarized_artifacts_fail_before_network(self):
        for notarized in (False, True):
            self.manifest(notarized)
            if notarized:
                (self.artifacts / "Zeus-0.2.0.zip").write_bytes(b"changed bytes")
            self.commands = []
            with patch.object(release, "run", self.fake_run), self.assertRaises(ValueError):
                release.publish(self.root, self.notes, resume=False)
            self.assertFalse(any(cmd[0] == "gh" or cmd[:2] == ["git", "tag"] for cmd in self.commands))

    def test_conflicting_upload_never_changes_appcast(self):
        self.manifest(); self.wrong_download = True
        before = (self.root / "appcast.xml").read_bytes()
        with patch.object(release, "run", self.fake_run), self.assertRaisesRegex(ValueError, "differs"):
            release.publish(self.root, self.notes, resume=False)
        self.assertEqual((self.root / "appcast.xml").read_bytes(), before)

    def test_stale_build_and_changed_resume_notes_fail_before_network(self):
        appcast.update_feed(self.root / "appcast.xml", "0.1.0", "6",
            "https://github.com/colinc86/zeus/releases/download/v0.1.0/Zeus-0.1.0.zip", signed(23), "notes")
        with patch.object(release, "run", self.fake_run), self.assertRaisesRegex(ValueError, "strictly exceed"):
            release.preflight(self.root, False, self.notes)
        (self.root / "appcast.xml").write_text(appcast.HEADER)
        self.manifest()
        (self.artifacts / "notes.md").write_text("original notes")
        with patch.object(release, "run", self.fake_run), self.assertRaisesRegex(ValueError, "notes changed"):
            release.publish(self.root, self.notes, resume=True)
        self.assertFalse(any(cmd[0] == "gh" for cmd in self.commands))

    def test_signing_checks_public_key_and_archive_length_without_key_export(self):
        self.manifest()
        tools = self.root / "build/SourcePackages/artifacts/sparkle/Sparkle/bin"
        tools.mkdir(parents=True)
        for name in ("generate_keys", "sign_update"):
            path = tools / name; path.write_text("fixture"); path.chmod(0o700)
        info = self.artifacts / "Zeus.app/Contents/Info.plist"; info.parent.mkdir(parents=True)
        def write_key(key):
            info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": self.version, "CFBundleVersion": "6",
                                           "SUFeedURL": release.FEED_URL, "SUPublicEDKey": key}))
        commands = []
        def fake_sign(args, **kwargs):
            commands.append([str(arg) for arg in args])
            if Path(args[0]).name == "generate_keys":
                self.assertEqual(args[1:], ["--account", "zeus", "-p"])
                return subprocess.CompletedProcess(args, 0, KEY, "")
            if Path(args[0]).name == "sign_update":
                self.assertEqual(args[1:3], ["--account", "zeus"])
                return subprocess.CompletedProcess(args, 0, signed(23), "")
            return subprocess.CompletedProcess(args, 0, "abc123\n", "")
        write_key("placeholder")
        with patch.object(release, "run", fake_sign):
            with self.assertRaisesRegex(ValueError, "SUPublicEDKey"):
                release.sign_archive(self.root, True)
            self.assertFalse(any(Path(cmd[0]).name == "sign_update" for cmd in commands))
            write_key(KEY)
            release.sign_archive(self.root, True)
        self.assertEqual(json.loads((self.artifacts / "publish.json").read_text())["build"], "6")
        self.assertFalse(any("-x" in cmd or "--export" in cmd for cmd in commands))

    def test_publish_requires_main_and_shell_rejects_invalid_option_combinations(self):
        real_mock = self.fake_run
        def wrong_branch(args, **kwargs):
            if args[:3] == ["git", "branch", "--show-current"]:
                return subprocess.CompletedProcess(args, 0, "task-branch\n", "")
            return real_mock(args, **kwargs)
        with patch.object(release, "run", wrong_branch), self.assertRaisesRegex(ValueError, "main"):
            release.preflight(self.root, False, self.notes)
        for args, message in ((["--resume"], "requires --publish"), (["--publish", ""], "requires a Markdown notes file"),
                              (["--publish", str(self.notes), "--no-notarize"], "cannot be combined")):
            result = subprocess.run(["bash", str(self.root / "scripts/release.sh"), *args], cwd=self.root,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
