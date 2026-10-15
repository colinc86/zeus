#!/usr/bin/env python3
"""LM2 native AX -> redactor -> encrypted journal, disposable HOME and owned app instances only."""
import argparse
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from OB1LiveProbe import Control as BaseControl
class Control(BaseControl):
    """Negative permission/launch results are evidence, rather than assertion failures."""
    def read(self):
        if not self.selector.select(timeout=45):
            raise TimeoutError("LM2 native host stalled")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("LM2 native host exited: " + str(self.process.poll()))
        return json.loads(line)

REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = REPO / "build/lm2-live"

def build_host():
    package = OUT / "host"
    source = package / "Sources/Host"
    shutil.rmtree(source, ignore_errors=True); source.mkdir(parents=True)
    inputs = ["Zeus/Learn/Seams.swift", "Zeus/Learn/LearnSettings.swift", "Zeus/Learn/ActivityStore.swift", "Zeus/Learn/LearningSummarizer.swift",
        "Zeus/Learn/Screen/ScreenSeams.swift", "Zeus/Settings/ObservationSettings.swift", "Zeus/Settings/FocusObserver.swift", "Zeus/Settings/FocusCaptureSource.swift", "Zeus/App/Tests/LM2NativeHost.swift"]
    inputs += [str(p.relative_to(REPO)) for folder in ["Zeus/Learn/Journal", "Zeus/Learn/Redactor"] for p in (REPO / folder).glob("*.swift")]
    for name in inputs: shutil.copyfile(REPO / name, source / pathlib.Path(name).name)
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "LM2Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.executableTarget(name: "Host", dependencies: [.product(name: "ZeusProtocol", package: "ZeusKit")], swiftSettings: [.define("LM2_PROBE_HOST")])])\n')
    with (OUT / "build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    binary = pathlib.Path(subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(package), "--show-bin-path"], text=True, timeout=30).strip()) / "Host"
    app = OUT / "LM2Fixture.app"; macos = app / "Contents/MacOS"; macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, macos / "LM2Fixture"); (macos / "LM2Fixture").chmod(0o755)
    with (app / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": "com.colinc86.Zeus", "CFBundleExecutable": "LM2Fixture", "CFBundleName": "Zeus LM2 Private Fixture", "CFBundlePackageType": "APPL",
            "LSUIElement": True, "NSPrincipalClass": "NSApplication", "CFBundleVersion": "1", "NSAppleEventsUsageDescription": "Synthetic private fixture capture only."}, info)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True, timeout=30)
    editor = OUT / "LM2Editor.app"
    editor_macos = editor / "Contents/MacOS"; editor_macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, editor_macos / "LM2Editor"); (editor_macos / "LM2Editor").chmod(0o755)
    with (editor / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": "com.example.LM2Editor", "CFBundleExecutable": "LM2Editor", "CFBundleName": "LM2 Synthetic Editor", "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication", "CFBundleVersion": "1"}, info)
    subprocess.run(["codesign", "--force", "--sign", "-", str(editor)], check=True, capture_output=True, timeout=30)
    return macos / "LM2Fixture"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode-clean-user", action="store_true", help="Run only from a clean macOS test user/VM; HOME alone does not isolate Xcode accounts")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    executable = build_host()
    with tempfile.TemporaryDirectory(prefix="zlm2_", dir="/tmp") as root:
        env = dict(HOME=root, CFFIXED_USER_HOME=root, PATH="/usr/bin:/bin")
        if args.xcode_clean_user: env["LM2_XCODE_CLEAN_USER_FIXTURE"] = "1"
        process = subprocess.Popen([str(executable), root], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=(OUT / "host.log").open("w"), text=True, bufsize=1, env=env)
        owned = []
        proof = {}
        try:
            control = Control(process); proof["launch"] = control.read()
            if not proof["launch"].get("ax_trusted"):
                proof["native_capture"] = {"status": "SKIP", "reason": "Accessibility unavailable for private dev app. No permission prompted."}
            else:
                launched = control.call("launchXcode")
                if launched.get("ok"):
                    process.stdin.write(json.dumps({"pid": launched["pid"], "bundle": "com.apple.dt.Xcode"}) + "\n"); process.stdin.flush()
                    proof["xcode"] = control.read()
                else:
                    proof["xcode"] = launched
                editor = control.call("launchEditor")
                process.stdin.write(json.dumps({"pid": editor["pid"], "bundle": "com.example.LM2Editor"}) + "\n"); process.stdin.flush()
                proof["native_editor"] = control.read()
            if "xcode" in proof:
                proof["xcode"]["status"] = "passed" if proof["xcode"].get("captured") else "fresh_process_exited" if proof["xcode"].get("owned_process_terminated") else "failed"
            if "native_editor" in proof:
                proof["native_editor"]["status"] = "passed" if all(proof["native_editor"].get(k) for k in ("captured", "document_read_from_ax", "synthetic_email_in_ax_title", "email_redacted")) else "failed"
            proof["safari"] = {"status": "not_run", "reason": "No verified disposable Safari profile; no user browser or history accessed."}
            proof["required_native_gate"] = "incomplete"
            (OUT / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
            print(json.dumps(proof), flush=True)
        finally:
            (OUT / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
            process.stdin.close()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=10)
            for child in owned:
                if child.poll() is None: child.terminate(); child.wait(timeout=15)

if __name__ == "__main__": main()
