#!/usr/bin/env python3
"""OB1 production native app walk: private HOME/socket, real Claude, localhost SSE.
No global events, screen capture, real credentials/config or default tmux access.
"""
import argparse
import http.server
import json
import os
import pathlib
import plistlib
import re
import selectors
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = REPO / "build/ob1-live"


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
    shutil.copyfile(REPO / "Zeus/App/Tests/OB1RuntimeHost.swift", source / "OB1RuntimeHost.swift")
    products = ",".join(f'.product(name: "{n}", package: "ZeusKit")' for n in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    sparkle = REPO / "build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
    assert sparkle.is_dir(), "Run build.sh first (Sparkle artifact)"
    local_sparkle = package / "Sparkle.xcframework"
    if not local_sparkle.exists(): local_sparkle.symlink_to(sparkle, target_is_directory=True)
    # Existing, approved Sparkle binary; no replacement driver or extra network dependency.
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "OB1Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.binaryTarget(name: "Sparkle", path: "Sparkle.xcframework"), .executableTarget(name: "Host", dependencies: [{products}, "Sparkle"], swiftSettings: [.define("OB1_PROBE_HOST")])])\n')
    with (OUT / "host-build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    binary_dir = subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(package), "--show-bin-path"], text=True, timeout=30).strip()
    binary_dir = pathlib.Path(binary_dir)
    app = OUT / "OB1Fixture.app"
    macos = app / "Contents/MacOS"; macos.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary_dir / "Host", macos / "OB1Fixture")
    (macos / "OB1Fixture").chmod(0o755)
    with (app / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": "local.zeus.ob1-fixture", "CFBundleExecutable": "OB1Fixture", "CFBundleName": "OB1 Fixture",
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
    return macos / "OB1Fixture"


class Control:
    def __init__(self, process):
        self.process = process
        self.selector = selectors.DefaultSelector()
        self.selector.register(process.stdout, selectors.EVENT_READ)

    def read(self):
        if not self.selector.select(timeout=25):
            raise TimeoutError("OB1 native host stalled")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("OB1 host exited: " + str(self.process.poll()))
        value = json.loads(line)
        assert value.get("ok", value.get("ready", False)), value
        return value

    def call(self, command, **fields):
        self.process.stdin.write(json.dumps(dict(command=command, **fields)) + "\n")
        self.process.stdin.flush()
        return self.read()

    def state(self):
        return self.call("state")["state"]


def eventually(check, description, timeout=65):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.08)
    raise TimeoutError(description)


class Model(http.server.BaseHTTPRequestHandler):
    scenario = "bootstrap"
    step = 0
    lock = threading.Lock()
    events = []
    acked = set()
    began = 0
    project = None

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.path.split("?")[0].endswith("count_tokens"):
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"input_tokens":1}'); return
        names = [t["name"] for t in body.get("tools", [])]
        with Model.lock:
            scenario, step = Model.scenario, Model.step
            target, arguments, delay = None, {}, 0
            results = [b for m in body.get("messages", []) if isinstance(m.get("content"), list)
                for b in m["content"] if b.get("type") == "tool_result"]
            if names and any(n == "zeus_say" or n.endswith("__zeus_say") for n in names):
                texts = [m.get("content") for m in body.get("messages", []) if m.get("role") == "user"]
                deliveries = re.findall(r'\[zeus delivery_id=([^\s\]]+)', json.dumps(texts))
                ack = deliveries[-1] if deliveries and deliveries[-1] not in Model.acked else None
                if ack:
                    Model.acked.add(ack); target, arguments = "zeus_ack", {"delivery_ids": [ack]}
                else:
                    Model.step += 1
                    if step == 0:
                        if scenario == "bootstrap": target, arguments = "zeus_say", {"text": "OB1 assistant connected. Ready when you are."}
                        elif scenario == "message":
                            target, arguments, delay = "zeus_say", {"text": "OB1 reply from your assistant. [Read the fixture guide](https://example.invalid/ob1). This reply checks the once-only typewriter and native accessible link."}, 2
                        else:
                            target, arguments = "zeus_ask", {"title": "OB1 " + scenario, "text": "Choose a private fixture path.",
                                "options": [{"id": "yes", "label": "OB1 Yes"}, {"id": "no", "label": "OB1 No"}], "wait_seconds": 60}
                name = next((n for n in names if n == target or n.endswith("__" + str(target))), None) if target else None
                if target and not name:
                    raise RuntimeError("Missing Claude tool " + target)
                Model.events.append({"t": time.monotonic() - Model.began, "scenario": scenario, "step": step,
                    "tool": target, "tool_results": results})
            elif names and scenario == "bootstrap" and "Read" in names:
                name, arguments, delay = "Read", {"file_path": str(Model.project / "AGENTS.md")}, 1
                Model.events.append({"t": time.monotonic() - Model.began, "scenario": scenario, "step": -1,
                    "tool": "Read (wait for launch-only MCP tools)", "tool_results": results})
            else:
                name = None
        if delay: time.sleep(delay)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def event(value):
            self.wfile.write(("event: " + value["type"] + "\ndata: " + json.dumps(value) + "\n\n").encode()); self.wfile.flush()
        event({"type": "message_start", "message": {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "model": body.get("model"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        content = {"type": "tool_use", "id": "tool_" + uuid.uuid4().hex, "name": name, "input": {}} if name else {"type": "text", "text": ""}
        event({"type": "content_block_start", "index": 0, "content_block": content})
        delta = {"type": "input_json_delta", "partial_json": json.dumps(arguments)} if name else {"type": "text_delta", "text": "OB1_DONE " + scenario}
        event({"type": "content_block_delta", "index": 0, "delta": delta}); event({"type": "content_block_stop", "index": 0})
        event({"type": "message_delta", "delta": {"stop_reason": "tool_use" if name else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}); event({"type": "message_stop"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true", help="Capture fresh launch only, before fixes")
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    executable = build_host()
    tmux, claude = shutil.which("tmux"), shutil.which("claude")
    assert tmux and claude
    bridge = REPO / "build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
    assert bridge.is_file(), "Run build.sh first"
    root = pathlib.Path(tempfile.mkdtemp(prefix="zob1_", dir="/tmp"))
    home, profile = root / "home", root / "home/.claude"
    profile.mkdir(parents=True)
    socket = str(root / "tmux.sock")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model); server.daemon_threads = True
    Model.began = time.monotonic()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "CLAUDE_CONFIG_DIR": str(profile),
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "xterm-256color",
        "ANTHROPIC_API_KEY": "ob1-local-fixture", "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false"}
    # Claude is synthetically signed in to the localhost endpoint; Zeus preferences/HOME start fresh.
    onboarding = {"hasCompletedOnboarding": True, "theme": "dark", "hasAcknowledgedCostThreshold": True}
    (home / ".claude.json").write_text(json.dumps(onboarding)); (profile / ".claude.json").write_text(json.dumps(onboarding))
    (profile / "settings.json").write_text(json.dumps({"permissions": {"allow": ["Read"], "ask": ["Bash"]}}))
    proof = {"claude": subprocess.check_output([claude, "--version"], env=env, text=True, timeout=10).strip(),
        "private_socket": True, "disposable_home": True, "localhost_model": True, "steps": [], "events": []}
    host = None
    tracked = {}
    def tm(*arguments):
        return subprocess.check_output([tmux, "-u", "-S", socket, "-f", "/dev/null", *arguments], env=env, text=True, timeout=10, stderr=subprocess.DEVNULL)
    def scrub(value):
        if isinstance(value, str):
            return value.replace(str(root.resolve()), "<fixture>").replace(str(root), "<fixture>").replace(str(REPO), "<worktree>")
        if isinstance(value, list): return [scrub(v) for v in value]
        if isinstance(value, dict): return {scrub(k): scrub(v) for k, v in value.items()}
        return value
    def track(pid):
        stamp = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
        if not stamp: return
        tracked[pid] = stamp
        for child in subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split(): track(int(child))
    def launch():
        nonlocal host
        host = subprocess.Popen([str(executable), str(root), str(bridge), claude, tmux], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=(OUT / "host.log").open("a"), env=env, text=True, bufsize=1)
        control = Control(host); ready = control.read(); track(host.pid)
        return control, ready
    def stop_host():
        host.stdin.close(); host.wait(timeout=15)
    def event(name, state):
        item = {"t": round(time.monotonic() - Model.began, 3), "step": name, "state": state}
        proof["steps"].append(item); print(json.dumps(scrub(item)), flush=True)
    try:
        control, ready = launch()
        eventually(lambda: control.state()["mounted"], "First run panel not mounted")
        event("1 fresh launch", control.state())
        proof["fresh_ax"] = control.call("ax")["nodes"]
        control.call("render"); shutil.copyfile(root / "conversation.png", OUT / "welcome.png")
        if args.baseline: return
        fresh = control.state()
        assert fresh["avatar"] == "idle" and fresh["menu"] == "Your assistant is off" and fresh["strip"] == "Your assistant is off"
        assert not fresh["notices"] and fresh["cards"][0]["seen"]
        assert len(ready["state"]["cards"]) == 1 and ready["state"]["cards"][0]["id"] == "c_welcome1", "Fresh launch lacks D19 welcome"
        eventually(lambda: control.state()["avatar"] == "idle", "Fresh welcome did not settle idle")
        control.call("press", label="Settings, Assistant")
        time.sleep(.6)
        proof["settings_ax"] = control.call("ax", settings=True)["nodes"]
        control.call("render", settings=True)
        shutil.copyfile(root / "settings.png", OUT / "settings.png")
        control.call("press", label="Create one for me", settings=True)
        folder = pathlib.Path(eventually(lambda: control.state()["folder"], "Create folder did not refresh"))
        Model.project = folder
        proof["templates_match"] = {name: (folder / name).read_bytes() == (REPO / "Zeus/Resources/AssistantTemplate" / name).read_bytes() for name in ["AGENTS.md", "CLAUDE.md"]}
        assert all(proof["templates_match"].values())
        event("2 created folder", control.state())
        control.call("press", label="Start", settings=True)
        event("3 Start clicked", control.state())
        eventually(lambda: control.state()["managed"] != "off", "Start never entered a lifecycle state")
        event("3 starting", control.state())
        def startup():
            state = control.state(); pane = state["pane"]
            if pane:
                text = tm("capture-pane", "-p", "-t", pane)
                if "Quick safety check:" in text and "Yes, I trust this folder" in text and folder.name in text:
                    tm("send-keys", "-t", pane, "Down", "Enter")
                    proof["events"].append({"operator": "Accepted trust of the newly created private fixture folder"})
                elif "Do you want to use this API key?" in text:
                    tm("send-keys", "-t", pane, "Up", "Enter")
                    proof["events"].append({"operator": "Accepted only the synthetic localhost API key"})
                elif state["managed"].startswith("blocked"):
                    card = next((c for c in state["cards"] if c["id"].startswith("managed-block_") and c["status"] == "open"), None)
                    if card and "development channels" in card["body"].lower():
                        proof["development_prompt"] = card
                        label = next(o["label"] for o in card["options"] if "local development" in o["label"].lower())
                        control.call("talk"); control.call("press", label=label)
            return state["can_input"] and state["sessions"] and "OB1_DONE bootstrap" in (tm("capture-pane", "-p", "-t", pane) if pane else "")
        eventually(startup, "Real Claude startup failed", 85)
        if control.state()["pane_pid"]: track(int(control.state()["pane_pid"]))
        control.call("talk")
        eventually(lambda: control.state()["avatar"] == "idle", "Startup did not settle idle")
        event("3 running", control.state())
        stable = {}
        def settled(scenario):
            state = control.state()
            native = control.call("snapshot")
            state = native["state"]
            idle = state["avatar"] == "idle" and state["phase"] is None and state["can_input"]
            if not idle or native["classification"] != "idle" or "OB1_DONE " + scenario not in native["screen"]:
                stable.pop(scenario, None)
                return False
            # Require a settled observation, not a one-frame gap before a receipt's activity publishes.
            now = time.monotonic()
            return state if now - stable.setdefault(scenario, now) >= .4 else False
        def contains_skipped(value):
            if isinstance(value, dict): return value.get("status") == "skipped" or any(contains_skipped(v) for v in value.values())
            if isinstance(value, list): return any(contains_skipped(v) for v in value)
            if isinstance(value, str):
                try: decoded = json.loads(value)
                except (ValueError, TypeError): return False
                return contains_skipped(decoded) if not isinstance(decoded, str) else False
            return False
        def run(scenario):
            with Model.lock: Model.scenario = scenario; Model.step = 0
            response = control.call("compose", text="OB1 " + scenario)
            proof["events"].append({"input": response["input"], "scenario": scenario, "t": time.monotonic() - Model.began})
        run("message")
        eventually(lambda: control.state()["avatar"] == "thinking", "Composer message never showed thinking")
        event("4 delivered and thinking", control.state())
        reply = eventually(lambda: next((c for c in control.state()["cards"] if c["body"].startswith("OB1 reply")), None), "Reply missing")
        eventually(lambda: settled("message"), "Reply did not finish its native turn and return idle")
        proof["reply_ax"] = control.call("ax")["nodes"]
        assert any(n["role"] == "AXLink" for n in proof["reply_ax"]), "Reply has no AX link"
        event("4 reply, revealed and idle", control.state())
        for scenario, action in [("option", "OB1 Yes"), ("skip", "Skip")]:
            run(scenario)
            eventually(lambda: control.state()["avatar"] == "waiting" and control.state()["strip"] == "Waiting for your answer", "Question did not show waiting")
            event("5 " + scenario + " waiting", control.state())
            control.call("press", label=action)
            eventually(lambda: settled(scenario), "Answer/Skip did not finish its native turn and return idle")
            event("5 " + scenario + " answered", control.state())
        assert any(contains_skipped(e["tool_results"]) for e in Model.events if e["scenario"] == "skip"), "Model never received skipped"
        before = control.state(); stop_host()
        proof["live_while_zeus_quit"] = tm("display-message", "-p", "-t", before["pane"], "#{pane_pid}|#{pane_dead}")
        control, ready = launch()
        eventually(lambda: control.state()["can_input"] and control.state()["sessions"], "Relaunch did not reconnect")
        after = control.state()
        assert all(before[k] == after[k] for k in ["pane", "pane_pid", "pane_start", "native_id", "nonce"]), "Relaunch changed native identity"
        event("6 same session reconnected", after)
        control.call("settings"); time.sleep(.25)
        control.call("off")
        assert control.state()["confirmation"] == "switchToOwn"
        proof["stop_ax"] = control.call("ax", settings=True)["nodes"]
        control.call("press", label="Stop", settings=True)
        eventually(lambda: not control.state()["enabled"] and control.state()["pane"] is None, "Stop did not release session")
        off = control.state()
        event("7 stopped and off", off)
        assert off["menu"] == "Your assistant is off" and off["strip"] == "Your assistant is off", "Off presentation is misleading"
    finally:
        if host and host.poll() is None:
            try:
                proof["final_native"] = control.call("snapshot") if control.state()["pane"] else None
                proof["final_ax"] = control.call("ax")["nodes"]
                control.call("render"); shutil.copyfile(root / "conversation.png", OUT / "conversation.png")
            except (RuntimeError, TimeoutError, AssertionError, BrokenPipeError): pass
        if host and host.poll() is None:
            try: stop_host()
            except (TimeoutError, subprocess.TimeoutExpired, BrokenPipeError): host.terminate(); host.wait(timeout=10)
        subprocess.run([tmux, "-S", socket, "kill-server"], env=env, capture_output=True, timeout=10)
        for pid, stamp in reversed(list(tracked.items())):
            current = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
            if current == stamp:
                try: os.kill(pid, signal.SIGTERM)
                except ProcessLookupError: pass
        server.shutdown(); server.server_close()
        proof["model_events"] = Model.events
        timeline = root / "timeline.jsonl"
        proof["timeline"] = [json.loads(line) for line in timeline.read_text().splitlines()] if timeline.exists() else []
        proof["typewriter_observed"] = any(any(c["body"].startswith("OB1 reply") and c.get("revealing") for c in row["cards"]) for row in proof["timeline"])
        name = "baseline" if args.baseline else "probe"
        (OUT / (name + ".json")).write_text(json.dumps(scrub(proof), indent=2) + "\n")
        if args.record:
            fixtures = REPO / "TestFixtures/live/ob1"; fixtures.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(OUT / (name + ".json"), fixtures / (name + ".json"))
        shutil.rmtree(root, ignore_errors=True)
    assert proof["typewriter_observed"], "The native reply never typed out"


if __name__ == "__main__":
    main()
