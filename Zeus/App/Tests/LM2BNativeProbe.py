#!/usr/bin/env python3
"""Runs production single-window capture only against an owned synthetic window in a disposable HOME. Never prompts."""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = REPO / "build/lm2b-native"

def main():
    source = OUT / "host/Sources/Host"
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir(parents=True)
    inputs = [REPO / "Zeus/Learn/Seams.swift", REPO / "Zeus/App/Tests/LM2BNativeHost.swift"]
    inputs += [p for folder in ["Journal", "Redactor", "Screen"] for p in (REPO / "Zeus/Learn" / folder).glob("*.swift")]
    for p in inputs:
        shutil.copyfile(p, source / p.name)
    package = OUT / "host"
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        'let package = Package(name: "LM2BNative", platforms: [.macOS(.v26)], dependencies: [.package(path: ' + json.dumps(str(REPO / "Packages/ZeusKit")) + ')], targets: [.executableTarget(name: "Host", dependencies: [.product(name: "ZeusProtocol", package: "ZeusKit")], swiftSettings: [.define("LM2B_PROBE_HOST")])])\n')
    with (OUT / "build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package)], stdout=log, stderr=subprocess.STDOUT, timeout=240, check=True)
    binary = pathlib.Path(subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(package), "--show-bin-path"], text=True, timeout=30).strip()) / "Host"
    app = OUT / "LM2BFixture.app"
    macos = app / "Contents/MacOS"; macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, macos / "LM2BFixture")
    with (app / "Contents/Info.plist").open("wb") as f:
        plistlib.dump({"CFBundleIdentifier": "local.zeus.lm2b", "CFBundleExecutable": "LM2BFixture", "CFBundleName": "Zeus LM2-B Isolated Fixture", "CFBundlePackageType": "APPL", "LSUIElement": True, "NSPrincipalClass": "NSApplication", "CFBundleVersion": "1"}, f)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True, timeout=30)
    with tempfile.TemporaryDirectory(prefix="zlm2b_") as home:
        env = {"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": home, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"}
        completed = subprocess.run([str(macos / "LM2BFixture"), home], env=env, cwd=home, capture_output=True, text=True, timeout=90)
        lines = [line for line in completed.stdout.splitlines() if line.startswith("{")]
        result = json.loads(lines[-1]) if lines else {"status": "blocked", "exit_code": completed.returncode, "reason": "No result from native host"}
        (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
