#!/usr/bin/env python3
"""Run the opt-in owned-editor gate against the built dev app, with a disposable HOME; never request permission."""
import json
import os
import platform
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
out = root / "build/lm2c-native"
out.mkdir(parents=True, exist_ok=True)
command = ["xcodebuild", "-project", "Zeus.xcodeproj", "-scheme", "Zeus", "-configuration", "Debug",
           "-destination", "platform=macOS,arch=" + platform.machine(), "-derivedDataPath", str(root / "build/DerivedData"),
           "-clonedSourcePackagesDirPath", str(root / "build/SourcePackages"),
           "test-without-building", "-only-testing:ZeusTests/TypingNativeTests"]
with tempfile.TemporaryDirectory(prefix="zlm2c-", dir=root / "build") as home:
    env = dict(os.environ)
    env.pop("ZEUS_TEST_LM2C_MODEL", None)
    env.pop("TEST_RUNNER_ZEUS_TEST_LM2C_MODEL", None)
    env.update(HOME=home, CFFIXED_USER_HOME=home, TEST_RUNNER_HOME=home, TEST_RUNNER_CFFIXED_USER_HOME=home,
               TEST_RUNNER_ZEUS_LM2C_HOME=home, TEST_RUNNER_ZEUS_TEST_LM2C_NATIVE="1")
    try:
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=120)
        log = result.stdout + result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        log = (error.stdout or b"").decode(errors="replace") + (error.stderr or b"").decode(errors="replace")
        code = 124
    (out / "native.log").write_text(log)
    evidence = [line for line in log.splitlines() if "LM2-C native gate blocked" in line or "Test run with" in line]
    report = {"exit_code": code, "disposable_home": True, "permission_requested": False, "evidence": evidence}
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(code)
