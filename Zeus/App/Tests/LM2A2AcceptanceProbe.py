#!/usr/bin/env python3
"""Phase A acceptance diagnostics: owned native processes, disposable HOME, no normal Safari data."""
import argparse
import json
import pathlib
import subprocess
import tempfile
from LM2AppLiveProbe import Control, build_host

REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = REPO / "build/lm2-a2-live"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode-clean-user", action="store_true", help="Run only from a clean macOS test user/VM; HOME alone does not isolate Xcode accounts")
    args = parser.parse_args()
    assert "** TEST SUCCEEDED **" in (REPO / "build/lm2-a2-test.log").read_text(), "Run the merged build/full test gates first"
    OUT.mkdir(parents=True, exist_ok=True)
    executable = build_host()
    proof = {"revision": subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, text=True).strip()}
    with tempfile.TemporaryDirectory(prefix="zlm2_", dir="/tmp") as root:
        with (OUT / "host.log").open("w") as log:
            env = {"HOME": root, "CFFIXED_USER_HOME": root, "PATH": "/usr/bin:/bin"}
            if args.xcode_clean_user: env["LM2_XCODE_CLEAN_USER_FIXTURE"] = "1"
            process = subprocess.Popen([str(executable), root], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                text=True, bufsize=1, env=env)
            try:
                control = Control(process)
                proof["launch"] = control.read()
                if proof["launch"].get("ax_trusted"):
                    launched = control.call("launchXcode")
                    proof["xcode_launch"] = {k: v for k, v in launched.items() if k != "pid"}
                    if launched.get("ok"):
                        process.stdin.write(json.dumps({"pid": launched["pid"], "bundle": "com.apple.dt.Xcode"}) + "\n"); process.stdin.flush()
                        proof["xcode"] = control.read()
                        passed = all(proof["xcode"].get(k) for k in ("captured", "document_read_from_ax", "synthetic_email_in_ax_title", "email_redacted"))
                        proof["xcode"]["status"] = "passed" if passed else "blocked"
                    else:
                        proof["xcode"] = {"status": "blocked", "reason": "Fresh Xcode process exited before capture", **proof["xcode_launch"]}
                else:
                    proof["xcode"] = {"status": "blocked", "reason": "Accessibility unavailable; no permission prompted"}
                status = proof["launch"].get("safari_automation_status")
                proof["safari"] = {"status": "blocked", "automation_status": status,
                    "reason": "Automation would require user consent; no prompt or browser data read" if status != 0 else "Permission available; isolated WebDriver capture still required"}
                proof["required_native_gate"] = "blocked"
                xcode_log = pathlib.Path(root) / "xcode-launch.log"
                if xcode_log.exists():
                    text = xcode_log.read_text(errors="replace").replace(root, "/FIXTURE").replace(str(pathlib.Path.home()), "/USER")
                    (OUT / "xcode-launch.log").write_text(text)
            finally:
                process.stdin.close()
                try: process.wait(timeout=20)
                except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=10)
                (OUT / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof, indent=2))
    return 1 if proof.get("required_native_gate") != "passed" else 0


if __name__ == "__main__": raise SystemExit(main())
