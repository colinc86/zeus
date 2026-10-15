#!/usr/bin/env python3
"""KR1 native recorder + real Carbon shortcut probe; disposable HOME, no agents/credentials."""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from OB1LiveProbe import Control
REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = REPO / "build/kr1-live"

def build_host():
    package = OUT / "host"
    source = package / "Sources/Host"
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir(parents=True)
    for path in (REPO / "Zeus").rglob("*.swift"):
        if "Tests" in path.relative_to(REPO / "Zeus").parts or path.name == "ZeusApp.swift":
            continue
        target = source / path.relative_to(REPO / "Zeus")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    shutil.copyfile(REPO / "Zeus/App/Tests/KR1RuntimeHost.swift", source / "KR1RuntimeHost.swift")
    products = ",".join(f'.product(name: "{n}", package: "ZeusKit")' for n in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    sparkle = REPO / "build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
    assert sparkle.is_dir(), "Run build.sh first (Sparkle artifact)"
    local_sparkle = package / "Sparkle.xcframework"
    if not local_sparkle.exists(): local_sparkle.symlink_to(sparkle, target_is_directory=True)
    # Existing, approved Sparkle binary; no replacement driver or extra network dependency.
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "KR1Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.binaryTarget(name: "Sparkle", path: "Sparkle.xcframework"), .executableTarget(name: "Host", dependencies: [{products}, "Sparkle"], swiftSettings: [.define("KR1_PROBE_HOST")])])\n')
    with (OUT / "host-build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    binary_dir = subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(package), "--show-bin-path"], text=True, timeout=30).strip()
    binary_dir = pathlib.Path(binary_dir)
    app = OUT / "KR1Fixture.app"
    macos = app / "Contents/MacOS"; macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary_dir / "Host", macos / "KR1Fixture")
    (macos / "KR1Fixture").chmod(0o755)
    with (app / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": "local.zeus.ob1-fixture", "CFBundleExecutable": "KR1Fixture", "CFBundleName": "KR1 Fixture",
            "CFBundlePackageType": "APPL", "LSUIElement": True, "NSPrincipalClass": "NSApplication", "CFBundleVersion": "1"}, info)
    # Keep SwiftPM's resource bundles and binary framework next to its executable.
    for resource in binary_dir.iterdir():
        if resource.suffix in [".bundle", ".framework"]:
            parent = app / "Contents/Resources" if resource.suffix == ".bundle" else macos
            parent.mkdir(parents=True, exist_ok=True)
            destination = parent / resource.name
            if destination.exists() or destination.is_symlink():
                if destination.is_symlink(): destination.unlink()
                else: shutil.rmtree(destination)
            destination.symlink_to(resource.resolve(), target_is_directory=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True, timeout=30)
    return macos / "KR1Fixture"

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    executable = build_host()
    with tempfile.TemporaryDirectory(prefix="zkr1_", dir="/tmp") as root:
        env = dict(HOME=root, CFFIXED_USER_HOME=root, PATH="/usr/bin:/bin:/opt/homebrew/bin")
        process = subprocess.Popen([str(executable), root], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=(OUT / "host.log").open("w"), text=True, bufsize=1, env=env)
        try:
            control = Control(process); proof = {"launch": control.read()}
            proof["record"] = control.call("record")
            assert proof["record"]["shortcut"] == "⌃⌥Space" and proof["record"]["error"] is None and proof["record"]["saved"], proof
            proof["fire"] = control.call("fire")
            (OUT / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
            assert proof["record"]["shortcut"] == "⌃⌥Space", proof
            assert proof["fire"]["opened"], proof
            print(json.dumps(proof), flush=True)
        finally:
            process.stdin.close()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=10)

if __name__ == "__main__": main()
