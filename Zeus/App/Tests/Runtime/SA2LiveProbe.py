#!/usr/bin/env python3
"""SA2 real managed Codex/OpenCode; private tmux/HOME and localhost model.

Run after build.sh. --record copies scrubbed successful/failing facts and ANSI
frames, never private profiles, to TestFixtures/live/sa2. No default tmux access.
"""
import argparse
import http.server
import json
import os
import pathlib
import re
import selectors
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[4]
OUT = REPO / "build/sa2-live"
OUT.mkdir(parents=True, exist_ok=True)


def build_host():
    package = OUT / "host"
    source = package / "Sources/Host"
    source.mkdir(parents=True, exist_ok=True)
    inputs = [REPO / p for p in ["Zeus/App/Tests/Runtime/SA2RuntimeHost.swift", "Zeus/Shared/AppSeams.swift",
        "Zeus/Cards/CardStore.swift", "Zeus/Cards/ThreadNotice.swift", "Zeus/Cards/AttachmentTarget.swift",
        "Zeus/Avatar/AvatarStatusModel.swift", "Zeus/Cards/ConversationActivityRow.swift"]]
    inputs += [p for area in ["Zeus/Bridge", "Zeus/Agents"] for p in (REPO / area).glob("*.swift") if p.name != "DebugSpriteFrameCounter.swift"]
    for path in inputs:
        shutil.copyfile(path, source / path.name)
    products = ",".join(f'.product(name: "{name}", package: "ZeusKit")' for name in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "SA2Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.executableTarget(name: "Host", dependencies: [{products}], swiftSettings: [.define("SA2_PROBE_HOST")])])\n')
    with (OUT / "host-build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package), "--product", "Host"], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    directory = subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(package), "--show-bin-path"], text=True, timeout=30).strip()
    return pathlib.Path(directory) / "Host"


class Model(http.server.BaseHTTPRequestHandler):
    steps = {}
    pauses = {}
    events = []
    lock = threading.Lock()
    began = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        chat = self.path.split("?")[0].endswith("/chat/completions")
        messages = body.get("messages" if chat else "input", [])
        users = [m.get("content", "") for m in messages if isinstance(m, dict) and m.get("role") == "user"]
        history = json.dumps(users)
        triggers = re.findall(r"SA2_(?:SAY|SHELL|FAST|BUSY|FOLLOWUP|DRAFT)", history)
        scenario = triggers[-1] if triggers else "bootstrap"
        ids = re.findall(r"delivery_id=(d_sa2_[a-z]+)", history)
        delivery = ids[-1] if ids else None
        tools = []
        for entry in body.get("tools", []):
            if entry.get("type") == "namespace":
                tools += [(nested.get("name", ""), entry["name"]) for nested in entry.get("tools", [])]
            else: tools.append((entry.get("function", entry).get("name", ""), None))
        names = [n for n, _ in tools]
        def name(target):
            found = next((n for n in names if n == target or n.endswith("__" + target) or n.endswith("_" + target)), None)
            if found is None: raise RuntimeError(f"No native {target} tool: {names}")
            return found
        with Model.lock:
            step = Model.steps.get(delivery, 0)
            tool, args = None, {}
            if delivery and step == 0:
                tool, args = name("zeus_ack"), {"delivery_ids": [delivery]}
            elif delivery and step == 1 and scenario in ["SA2_SAY", "SA2_FOLLOWUP"]:
                tool, args = name("zeus_say"), {"text": scenario + " native bridge reply."}
            elif delivery and step == 1:
                tool = name("exec_command" if "exec_command" in names else "bash")
                args = {"cmd": "printf SA2_SHELL_DONE"} if tool == "exec_command" else {"command": "printf SA2_SHELL_DONE", "description": "Print the isolated state fixture marker"}
            Model.steps[delivery] = step + 1
            Model.events.append({"t": time.monotonic() - Model.began, "scenario": scenario, "delivery": delivery, "step": step, "tool": tool,
                "tool_results": [m for m in messages if isinstance(m, dict) and (m.get("type") == "function_call_output" or m.get("role") == "tool")]})
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode()); self.wfile.flush()
        pause = Model.pauses.get(scenario) if delivery and step >= 2 and not tool else None
        text = "SA2_READY" if not delivery else scenario + " native turn complete."
        try:
            if chat:
                chunk = {"id": "chat_fixture", "object": "chat.completion.chunk", "created": int(time.time()), "model": body.get("model", "fixture"),
                    "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]}
                event(chunk)
                if pause: pause.wait(timeout=45)
                delta = {"tool_calls": [{"index": 0, "id": "call_" + uuid.uuid4().hex, "type": "function", "function": {"name": tool, "arguments": json.dumps(args)}}]} if tool else {"content": text}
                chunk["choices"][0] = {"index": 0, "delta": delta, "finish_reason": None}; event(chunk)
                chunk["choices"][0] = {"index": 0, "delta": {}, "finish_reason": "tool_calls" if tool else "stop"}; event(chunk)
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
            else:
                item = {"id": "fc_" + uuid.uuid4().hex, "type": "function_call", "name": tool, "call_id": "call_" + uuid.uuid4().hex,
                    "arguments": json.dumps(args), "status": "completed"} if tool else {
                    "id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": text, "annotations": []}]}
                namespace = next((ns for n, ns in tools if n == tool), None)
                if namespace: item["namespace"] = namespace
                response = {"id": "resp_" + uuid.uuid4().hex, "object": "response", "created_at": int(time.time()), "status": "completed", "model": "fixture",
                    "output": [item], "error": None, "incomplete_details": None, "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
                event({"type": "response.created", "response": dict(response, status="in_progress", output=[])})
                event({"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress")})
                if pause: pause.wait(timeout=45)
                if not tool:
                    event({"type": "response.content_part.added", "item_id": item["id"], "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}})
                    event({"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0, "content_index": 0, "delta": text})
                event({"type": "response.output_item.done", "output_index": 0, "item": item})
                event({"type": "response.completed", "response": response})
        except (BrokenPipeError, ConnectionResetError):
            pass


class Probe:
    def __init__(self, executable, agent):
        self.agent = agent; self.tmux = shutil.which("tmux"); self.cli = shutil.which(agent)
        assert self.tmux and self.cli
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="zsa2_", dir="/tmp")).resolve()
        home = self.root / "home"; (self.root / "project").mkdir()
        self.env = {"HOME": str(home), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "USER": "fixture", "LOGNAME": "fixture", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "xterm-256color",
            "CODEX_HOME": str(home / ".codex"), "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
            "XDG_CACHE_HOME": str(home / ".cache"), "XDG_STATE_HOME": str(home / ".local/state"), "TMUX_TMPDIR": str(home / "tmux"),
            "OPENCODE_DISABLE_AUTOUPDATE": "true", "OPENCODE_DISABLE_EXTERNAL_PLUGINS": "true", "OPENCODE_DISABLE_MODELS_FETCH": "true", "OPENCODE_DISABLE_LSP_DOWNLOAD": "true"}
        for key in ["HOME", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "TMUX_TMPDIR"]:
            pathlib.Path(self.env[key]).mkdir(parents=True, exist_ok=True)
        self.version = subprocess.check_output([self.cli, "--version"], env=self.env, text=True, timeout=10).strip()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True); self.worker.start()
        Model.steps = {}; Model.events = []; Model.began = time.monotonic()
        Model.pauses = {scenario: threading.Event() for scenario in ["SA2_SHELL", "SA2_BUSY", "SA2_DRAFT"]}
        self.began = Model.began; self.frames = {}; self.events = []; self.scenarios = []
        self.bridge = REPO / "build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
        self.log = (OUT / (agent + "-host.log")).open("w")
        self.host = subprocess.Popen([str(executable), str(self.root), str(self.bridge), agent, self.cli, self.tmux, f"http://127.0.0.1:{self.server.server_port}"],
            env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True)
        self.selector = selectors.DefaultSelector(); self.selector.register(self.host.stdout, selectors.EVENT_READ)
        self.read()

    def read(self):
        if not self.selector.select(timeout=15): raise TimeoutError("SA2 host response stalled")
        value = json.loads(self.host.stdout.readline())
        if not value.get("ok", value.get("ready", False)): raise RuntimeError(value)
        return value

    def call(self, command, **kwargs):
        self.host.stdin.write(json.dumps(dict(command=command, **kwargs)) + "\n"); self.host.stdin.flush()
        return self.read()

    def state(self): return self.call("state")["state"]

    def wait(self, check, description, timeout=45):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            value = check()
            if value: return value
            if self.host.poll() is not None: raise RuntimeError("Host exited: " + self.log.name)
            time.sleep(.05)
        raise TimeoutError(description + ": " + json.dumps(self.state()))

    def tm(self, *args, input=None):
        return subprocess.check_output([self.tmux, "-u", "-S", str(self.root / "tmux.sock"), *args], env=self.env, input=input, text=True, timeout=10)

    def snapshot(self, name):
        frame = self.call("snapshot")["snapshot"]; self.frames[name] = frame
        return frame

    def event(self, trigger):
        value = {"t": time.monotonic() - self.began, "trigger": trigger, "state": self.state()}; self.events.append(value)
        print(json.dumps({"agent": self.agent, **value}), flush=True)
        return value

    def native_idle(self, marker):
        # The real CLI's completed text is the fixture's causal turn marker;
        # classification is reported independently and never used as the oracle.
        frame = self.call("snapshot")["snapshot"]
        plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", frame["screen"])
        after = plain[plain.rfind(marker) + len(marker):] if marker in plain else ""
        completed = re.search(r"(?m)^  Worked for .+ • \d", after) if self.agent == "codex" else re.search(r"▣  Build · .+ · \d+(?:\.\d+)?(?:ms|s)", after)
        return frame if completed and "esc to interrupt" not in plain.lower() and "esc interrupt" not in plain.lower() else None

    def finish(self, scenario, prompt=None, frame=None):
        if frame is None: frame = self.wait(lambda: self.native_idle(scenario + " native turn complete."), "Native prompt did not return")
        if prompt is None: prompt = self.event("native prompt returned: " + scenario)
        self.frames[scenario.lower() + "-idle"] = frame
        end = self.wait(lambda: (s if (s := self.state())["phase"] is None and s["managed"].endswith(".idle)") else None), "Managed activity did not end", timeout=30)
        done = self.event("activity ended: " + scenario)
        delta = done["t"] - prompt["t"]
        result = {"name": scenario, "native_prompt_t": prompt["t"], "ended_t": done["t"], "idle_after_prompt_s": delta, "within_5s": delta <= 5, "native_classification": frame["classification"]}
        self.scenarios.append(result)
        return end

    def run(self):
        self.wait(lambda: (s if (s := self.state())["sessions"] > 0 and s["managed"].endswith(".idle)") else None), "Managed startup", timeout=70)
        self.snapshot("initial-idle"); self.event("managed ready")
        for scenario in ["SA2_SAY", "SA2_SHELL", "SA2_FAST", "SA2_BUSY", "SA2_DRAFT"]:
            self.call("send", text=scenario, id="d_sa2_" + scenario[4:].lower()); self.event("user message: " + scenario)
            self.wait(lambda: any(e["scenario"] == scenario and e["step"] >= 2 for e in Model.events), "Native tools never finished")
            if scenario in Model.pauses:
                self.snapshot(scenario.lower() + "-working")
                self.wait(lambda: self.state()["managed"].endswith(".working)"), "Working not sampled", timeout=8)
                self.event("working sampled: " + scenario)
                if scenario == "SA2_BUSY":
                    response = self.call("send", text="SA2_FOLLOWUP", id="d_sa2_followup")
                    assert response["result"].startswith("queued"), response
                    assert any(d["id"] == "d_sa2_followup" and d["attempts"] == 0 for d in response["state"]["deliveries"]), response
                    time.sleep(3.2)
                    state = self.event("queued mid-turn input retains thinking")["state"]
                    assert state["phase"] == "thinking" and state["activity_delivery"] == "d_sa2_busy", state
                    assert not any(e["scenario"] == "SA2_FOLLOWUP" for e in Model.events), "Native followup started during the held turn"
                Model.pauses[scenario].set()
                if scenario == "SA2_BUSY":
                    frame = self.wait(lambda: self.native_idle(scenario + " native turn complete."), "Busy native turn never ended")
                    self.frames["sa2_busy-idle"] = frame
                    prompt = self.event("native prompt returned: SA2_BUSY")
                    self.wait(lambda: self.state()["activity_delivery"] != "d_sa2_busy", "Original busy row was not released")
                    done = self.event("original busy activity released")
                    delta = done["t"] - prompt["t"]
                    self.scenarios.append({"name": scenario, "native_prompt_t": prompt["t"], "ended_t": done["t"], "idle_after_prompt_s": delta,
                        "within_5s": delta <= 5, "native_classification": frame["classification"]})
            frame = prompt = None
            if scenario == "SA2_DRAFT":
                frame = self.wait(lambda: self.native_idle(scenario + " native turn complete."), "Draft turn did not end")
                prompt = self.event("native prompt returned: " + scenario)
                pane = self.state()["pane"]
                self.tm("load-buffer", "-b", "sa2-draft", "-", input="SA2 deliberately unsent draft.")
                self.tm("paste-buffer", "-p", "-d", "-b", "sa2-draft", "-t", pane)
            self.finish("SA2_FOLLOWUP" if scenario == "SA2_BUSY" else scenario, prompt=prompt, frame=frame)
            state = self.state()
            assert any(d["id"] == "d_sa2_" + scenario[4:].lower() and d["acked"] and d["attempts"] == 1 for d in state["deliveries"]), state
            if scenario in ["SA2_SAY", "SA2_BUSY"]:
                expected = ("SA2_FOLLOWUP" if scenario == "SA2_BUSY" else scenario) + " native bridge reply."
                assert any(c["body"] == expected for c in state["cards"]), state
            if scenario == "SA2_DRAFT":
                self.wait(lambda: self.state()["draft"] == "SA2 deliberately unsent draft.", "Draft was not preserved")
                self.snapshot("typed-draft"); self.event("idle with human draft; no activity")
        return self.proof()

    def proof(self):
        return {"agent": self.agent, "version": self.version, "private_socket": True, "disposable_home": True, "localhost_model": True,
            "events": self.events, "scenarios": self.scenarios, "frames": self.frames, "model_events": Model.events,
            "timeline": [json.loads(line) for line in (self.root / "timeline.jsonl").read_text().splitlines()]}

    def close(self):
        for pause in Model.pauses.values(): pause.set()
        try:
            self.call("stop")
            self.wait(lambda: self.state()["managed"] == "stopped", "Owned managed pane stop", timeout=8)
        except (RuntimeError, TimeoutError, BrokenPipeError): pass
        self.host.stdin.close()
        try: self.host.wait(timeout=5)
        except subprocess.TimeoutExpired: self.host.kill(); self.host.wait()
        # Inspect only our namespace. Any remaining pane children belong to this fixture.
        owned = []
        try:
            owned = [int(p) for p in self.tm("list-panes", "-a", "-F", "#{pane_pid}").split()]
        except subprocess.CalledProcessError: pass
        for pid in owned:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        subprocess.run([self.tmux, "-S", str(self.root / "tmux.sock"), "kill-server"], env=self.env, capture_output=True, timeout=10)
        self.server.shutdown(); self.server.server_close(); self.worker.join(timeout=2); self.selector.close(); self.log.close()
        shutil.rmtree(self.root)


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("--record", action="store_true")
    parser.add_argument("--agent", choices=["all", "codex", "opencode"], default="all"); args = parser.parse_args()
    executable = build_host(); failures = []
    for agent in ["codex", "opencode"] if args.agent == "all" else [args.agent]:
        probe = Probe(executable, agent)
        try:
            try: proof = probe.run()
            except Exception as error:
                proof = probe.proof(); proof["error"] = str(error); failures.append(agent)
            if any(not s["within_5s"] for s in proof["scenarios"]): failures.append(agent)
            raw = json.dumps(proof, ensure_ascii=False, indent=2)
            (OUT / (agent + "-proof.json")).write_text(raw)
            scrubbed = raw.replace(str(probe.root), "/FIXTURE").replace(str(probe.bridge.parent.parent.parent), "/BUNDLE/Zeus.app").replace(probe.cli, "/CLI/" + agent)
            if args.record:
                target = REPO / "TestFixtures/live/sa2"; target.mkdir(parents=True, exist_ok=True)
                (target / (agent + "-probe.json")).write_text(scrubbed + "\n")
            print(json.dumps({"agent": agent, "scenarios": proof["scenarios"], "error": proof.get("error")}), flush=True)
        finally: probe.close()
    if args.record and args.agent == "all": write_transcript()
    if failures: raise SystemExit("SA2 gates failed: " + ", ".join(failures))


def write_transcript():
    target = REPO / "TestFixtures/live/sa2"
    proofs = [json.loads((target / (a + "-probe.json")).read_text()) for a in ["codex", "opencode"]]
    lines = ["# SA2 — managed Codex and OpenCode state accuracy", "",
        "Recorded 2026-10-14 with " + ", ".join(p["version"] for p in proofs) + ".",
        "Real installed CLIs, production managed launch/controller/runtime, real bundled zeus-mcp, CardStore, AvatarStatusModel and thread activity mapping. Private 120×40 tmux panes, disposable HOME/XDG/config, localhost deterministic SSE models; no human server, config or credentials.", "",
        "## Measured state transitions", "",
        "Each agent has its own parent monotonic clock. Prompt return requires the causal final model text, the CLI's native completed-turn summary below it, and no live interrupt control; it is not inferred from the runtime classifier. The host's real 3-second monitor is never manually refreshed. End deltas use the same parent clock; raw host timeline timestamps have their own startup origin. Measurements include sampling and IPC latency.", "",
        "| Agent | Trigger | Native prompt t | Activity released t | Δ after prompt | ≤5 s |",
        "|---|---|---:|---:|---:|---|"]
    for proof in proofs:
        for s in proof["scenarios"]:
            lines.append(f'| {proof["agent"]} | {s["name"]} | {s["native_prompt_t"]:.3f} | {s["ended_t"]:.3f} | {s["idle_after_prompt_s"]:.3f} s | {"pass" if s["within_5s"] else "FAIL"} |')
    lines += ["", "SAY and FOLLOWUP require an actual zeus_say card in the production store. SHELL/FAST/BUSY/DRAFT run a real native shell tool (`printf SA2_SHELL_DONE`) and end with terminal-only output: no zeus_say, zeus_set_status or other clear signal. Every message is really acked at attempt 1. SHELL waits for an observed working sample; FAST completes without a deliberate hold. BUSY queues a second message while the first response is held, verifies attempts 0/no native model arrival and retains the original thinking row, then releases the original delivery's activity before finishing FOLLOWUP. DRAFT adds deliberately unsent text after positive native completion and verifies idle, draft preservation and no activity.", "",
        "The SAY card's earned 2.5-second talking transient can briefly outrank the next thinking avatar; the thread row follows assistantActivity. BUSY's released timestamp is for its original delivery, not a forced empty UI while the queued followup is producing a response. The final followup and all no-say cases end idle with no activity row.", "",
        "## Baseline and fix", ""]
    for proof in proofs:
        before = json.loads((target / (proof["agent"] + "-before.json")).read_text())
        old = next(s for s in before["scenarios"] if s["name"] == "SA2_FAST")
        new = next(s for s in proof["scenarios"] if s["name"] == "SA2_FAST")
        lines.append(f'- {proof["agent"]}: the fast shell turn missed the 3-second working samples and retained thinking for {old["idle_after_prompt_s"]:.3f} s after native idle; fixed release {new["idle_after_prompt_s"]:.3f} s.')
    lines += ["", "The recorded working/idle/draft classifiers already pass both agents. The fix recognizes Codex's native `Worked for … • time` summary and OpenCode's native `▣ … · model · duration` summary only in history above a bounded composer. The summary must follow the latest Zeus envelope, and its delivery ID must equal the existing activity record, with a fresh positive idle sample. An old footer, new input echo, malformed envelope, composer/footer text, or unrelated delivery cannot release a newer response. It never creates activity and does not end explicit statuses. SA1's separate generic TTL-preservation fix must be retained when merging the Activity file; SA2 does not alter that working-screen branch or add a competing ActivityRecord property.", "",
        "## State / trigger transcript", "",
        "Milestones below are parent-clock queries; the scrubbed probe JSON also retains the 50-ms changed-state host timeline, all ownership-checked ANSI/cursor captures and actual native tool results.", "",
        "| Agent | t | Trigger | Managed state | Activity | Avatar | Draft |",
        "|---|---:|---|---|---|---|---|"]
    for proof in proofs:
        for e in proof["events"]:
            s = e["state"]
            lines.append(f'| {proof["agent"]} | {e["t"]:.3f} | {e["trigger"]} | {s["managed"].replace("Host.", "")} | {s["phase"] or "none"} | {s["avatar"]} | {s["draft"] or "none"} |')
    lines += ["", "## Boundaries and reproduction", "",
        "These are headless production-path measurements, not pixel renders or UI clicks. Model output is deterministic; native tools, MCP subprocesses, delivery receipts, clocks and TUI rendering are real. Only private paths/executable locations are scrubbed; ANSI, wrapping, elapsed times, opaque IDs and cursor metadata are preserved. `*-before.json` is the full valid pre-fix matrix (FAST is its expected failing gate). `*-probe.json` is the fixed matrix. Early harness-development runs are not included.", "",
        "No dependable new completion is asserted if a long output scrolls its Zeus envelope offscreen, a narrow pane wraps that header before its closing bracket, or an unrecognized native version omits the summary. Those cases retain the observed-working → idle rule and conservative 20-second grace. The TUI *does* provide usable working/idle evidence in the installed versions; no speculative notification or timeout replacement is added. Connect-your-own sessions are outside this managed-session task.", "",
        "Fake-clock tests replay recorded screens for both agents: fast completion without a working sample, old delivery, echo without completion, active work, queued input, idle with draft, no resurrection, composer/footer exclusion, malformed envelope and explicit-status preservation. Shared/CONTRACT/app-owned production files are unchanged.", "",
        "```sh", "scripts/build.sh", "python3 -B Zeus/App/Tests/Runtime/SA2LiveProbe.py --record", "scripts/test.sh", "scripts/check-public.sh", "```", "",
        "The live probe is opt-in; normal test.sh uses the recorded fixtures. All spawned host/model/pane processes and disposable directories are cleaned up."]
    (target / "transcript.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__": main()
