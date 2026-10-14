#!/usr/bin/env python3
"""Real Claude + production headless runtime; private tmux/HOME and localhost model.

Run from the worktree root after scripts/build.sh: python3 -B Zeus/App/Tests/Runtime/AC1LiveProbe.py
Only writes under build/ and its own /tmp scratch; never reads agent configs/credentials.
"""
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[4]
OUT = REPO / "build/ac1-live"
OUT.mkdir(parents=True, exist_ok=True)


def build_host():
    package = OUT / "host"
    source = package / "Sources/Host"
    source.mkdir(parents=True, exist_ok=True)
    inputs = [REPO / p for p in ["TestFixtures/E2EHost/RuntimeHost.swift", "Zeus/Shared/AppSeams.swift", "Zeus/Cards/CardStore.swift", "Zeus/Cards/AttachmentTarget.swift"]]
    # AC2/L1's shared notice foundation lands in parallel; include it when present.
    if (REPO / "Zeus/Cards/ThreadNotice.swift").is_file():
        inputs.append(REPO / "Zeus/Cards/ThreadNotice.swift")
    inputs += [p for area in ["Zeus/Bridge", "Zeus/Agents"] for p in (REPO / area).glob("*.swift") if p.name != "DebugSpriteFrameCounter.swift"]
    for path in inputs:
        shutil.copyfile(path, source / path.name)
    dependency = json.dumps(str(REPO / "Packages/ZeusKit"))
    products = ",".join(f'.product(name: "{name}", package: "ZeusKit")' for name in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    (package / "Package.swift").write_text(f'// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "AC1Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {dependency})], targets: [.executableTarget(name: "Host", dependencies: [{products}])])\n')
    with (OUT / "host-build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package), "--product", "Host"], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    binary_dir = subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(package), "--show-bin-path"], text=True).strip()
    return pathlib.Path(binary_dir) / "Host"


class Model(http.server.BaseHTTPRequestHandler):
    stage = 0
    results = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.path.split("?")[0].endswith("count_tokens"):
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"input_tokens":1}'); return
        names = [tool["name"] for tool in body.get("tools", [])]
        with Model.lock:
            stage = Model.stage
            target = "zeus_app_state" if stage == 0 else "zeus_move" if stage == 1 else None
            name = next((n for n in names if n.endswith("__" + target)), None) if target else None
            if target and not name:
                raise RuntimeError(f"Expected {target} in real Claude model tools: {names}")
            Model.stage += 1
            Model.results = [block for message in body.get("messages", []) if isinstance(message.get("content"), list)
                for block in message["content"] if block.get("type") == "tool_result"]
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def event(value):
            self.wfile.write(("event: " + value["type"] + "\ndata: " + json.dumps(value) + "\n\n").encode()); self.wfile.flush()
        event({"type": "message_start", "message": {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "model": body.get("model"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        content = {"type": "tool_use", "id": "tool_" + uuid.uuid4().hex, "name": name, "input": {}} if name else {"type": "text", "text": ""}
        event({"type": "content_block_start", "index": 0, "content_block": content})
        delta = {"type": "input_json_delta", "partial_json": json.dumps({"position": "near-active-window"} if target == "zeus_move" else {})} if name else {"type": "text_delta", "text": "AC1_PROVED"}
        event({"type": "content_block_delta", "index": 0, "delta": delta}); event({"type": "content_block_stop", "index": 0})
        event({"type": "message_delta", "delta": {"stop_reason": "tool_use" if name else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}); event({"type": "message_stop"})


def main():
    executable = build_host()
    tmux, claude = shutil.which("tmux"), shutil.which("claude")
    assert tmux and claude, "tmux and Claude must be installed"
    root = pathlib.Path(tempfile.mkdtemp(prefix="zac1_", dir="/tmp"))
    home, project = root / "home", root / "project"
    profile = home / ".claude"
    profile.mkdir(parents=True); project.mkdir()
    socket = str(root / "tmux.sock")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    env = {"HOME": str(home), "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "xterm-256color", "ZEUS_AC1_HOST": "1"}
    host = None
    try:
        host = subprocess.Popen([str(executable), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(OUT / "host.log").open("w"), env=env, text=True)
        ready = json.loads(host.stdout.readline()); assert ready["ready"]
        bridge = REPO / "build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
        assert bridge.is_file(), "Build the branch's dev app first"
        config = root / "mcp.json"
        config.write_text(json.dumps({"mcpServers": {"zeus": {"command": str(bridge), "args": ["--agent", "claude", "--socket", str(root / "bridge.sock")]}}}))
        env.update({"CLAUDE_CONFIG_DIR": str(profile), "ANTHROPIC_API_KEY": "ac1-local-fixture", "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false"})
        onboarding = {"hasCompletedOnboarding": True, "hasAcknowledgedCostThreshold": True, "projects": {str(project): {"hasTrustDialogAccepted": True}}}
        (home / ".claude.json").write_text(json.dumps(onboarding)); (profile / ".claude.json").write_text(json.dumps(onboarding))
        version = subprocess.check_output([claude, "--version"], env=env, text=True).strip()
        argv = [claude, "-p", "AC1_LIVE: the user requests Zeus's app state and then a move near the active window. Use the Zeus tools.", "--model", "claude-haiku-4-5", "--permission-mode", "manual", "--mcp-config", str(config), "--allowedTools", "mcp__zeus__zeus_app_state,mcp__zeus__zeus_move", "--output-format", "stream-json", "--verbose"]
        launcher = root / "launch.py"
        launcher.write_text("import json,subprocess,pathlib\n" + f"argv=json.loads({json.dumps(json.dumps(argv))})\nenv=json.loads({json.dumps(json.dumps(env))})\n" + f"with open({str(OUT / 'claude.jsonl')!r},'w') as log: result=subprocess.run(argv,env=env,stdout=log,stderr=subprocess.STDOUT)\npathlib.Path({str(root / 'exit')!r}).write_text(str(result.returncode))\n")
        subprocess.run([tmux, "-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "ac1", "-x", "120", "-y", "40", "-c", str(project), sys.executable, str(launcher)], env=env, check=True)
        deadline = time.monotonic() + 90
        while not (root / "exit").exists():
            if time.monotonic() > deadline: raise TimeoutError("Claude probe did not exit; see build/ac1-live/claude.jsonl")
            time.sleep(.1)
        assert (root / "exit").read_text() == "0"
        calls = [json.loads(line) for line in (root / "app-control.jsonl").read_text().splitlines()]
        assert any(c["call"] == "state" for c in calls) and sum(c["call"] == "move" for c in calls) == 1, calls
        assert len(Model.results) == 2 and all(not result.get("is_error", False) for result in Model.results), Model.results
        summary = {"claude": version, "pane": "120x40", "private_socket": True, "disposable_home": True, "localhost_model": True, "app_state_received": True, "moves": 1, "tool_results": Model.results}
        (OUT / "proof.json").write_text(json.dumps(summary, indent=2)); print(json.dumps(summary), flush=True)
    finally:
        subprocess.run([tmux, "-S", socket, "kill-server"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        if host:
            host.stdin.close()
            try: host.wait(timeout=5)
            except subprocess.TimeoutExpired: host.kill(); host.wait()
        server.shutdown(); server.server_close(); thread.join(timeout=2)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
