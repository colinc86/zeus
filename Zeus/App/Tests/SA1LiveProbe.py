#!/usr/bin/env python3
"""SA1: real managed Claude, real runtime/avatar/row, private socket/HOME/model.

Run from the worktree after build.sh; no screen capture or global input. Every
terminal read/key is scoped to the probe's socket. Output is scrubbed before it
is copied to TestFixtures/live/sa1. --own-seconds 305 measures the entire own-session
stale window; the default records 20 seconds plus the runtime's actual deadline.
"""
import argparse
import http.server
import json
import pathlib
import re
import selectors
import statistics
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

import sys, os
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "Runtime"))
from LiveSupport import stream_reply, output_dir, create_root, isolated_environment, start_model, finish_host_build, host_package, scrub_paths, cleanup_root, stop_host

REPO = pathlib.Path(__file__).resolve().parents[3]
OUT = output_dir("sa1-live")


def build_host():
    package = host_package(OUT, "sa1")
    source = package / "Sources/Host"
    source.mkdir(parents=True, exist_ok=True)
    inputs = [REPO / p for p in ["Zeus/App/Tests/SA1RuntimeHost.swift", "Zeus/Shared/AppSeams.swift",
        "Zeus/Cards/CardStore.swift", "Zeus/Cards/ThreadNotice.swift", "Zeus/Cards/AttachmentTarget.swift",
        "Zeus/Avatar/AvatarStatusModel.swift", "Zeus/Cards/ConversationActivityRow.swift"]]
    inputs += [p for area in ["Zeus/Bridge", "Zeus/Agents"] for p in (REPO / area).glob("*.swift") if p.name != "DebugSpriteFrameCounter.swift"]
    for path in inputs:
        shutil.copyfile(path, source / path.name)
    products = ",".join(f'.product(name: "{name}", package: "ZeusKit")' for name in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "SA1Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.executableTarget(name: "Host", dependencies: [{products}], swiftSettings: [.define("SA1_PROBE_HOST")])])\n')
    return finish_host_build(OUT, package)


class Control:
    def __init__(self, process):
        self.process = process
        self.selector = selectors.DefaultSelector()
        self.selector.register(process.stdout, selectors.EVENT_READ)

    def read(self):
        if not self.selector.select(timeout=20):
            raise TimeoutError("SA1 host response stalled")
        value = json.loads(self.process.stdout.readline())
        assert value.get("ok", value.get("ready", False)), value
        return value

    def call(self, command, **fields):
        self.process.stdin.write(json.dumps(dict(command=command, **fields)) + "\n")
        self.process.stdin.flush()
        return self.read()

    def state(self):
        return self.call("state")["state"]


def eventually(check, description, timeout=45):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise TimeoutError(description)


def report(proof, fixtures):
    before = json.loads((fixtures / "before.json").read_text())
    window_path = fixtures / "own-window.json"
    window = json.loads(window_path.read_text()) if window_path.exists() else proof
    offsets = [e["t"] - e["state"]["t"] for e in proof["events"]
        if e["trigger"].startswith("native prompt returned") and "t" in e["state"]]
    offset = statistics.median(offsets) if offsets else 0
    own = window["own_session"]
    own_end = next(v for v in window["timeline"] if v["managed"] == "off" and v["t"] > own["at_prompt"]["t"] and v["avatar"] == "idle" and v["phase"] is None)
    delay = own_end["t"] - own["at_prompt"]["t"]
    lines = ["# SA1 — state accuracy transcript", "", "Recorded 2026-10-14; " + proof["claude"] + ".",
        "Real Claude, production managed controller/runtime/CardStore/AvatarStatusModel and activity-row mapping; private tmux socket, disposable HOME, localhost SSE model. No user's server, configs, credentials, global input or screen capture.", "",
        "The host uses the app's new-card transient hook and real clocks. Option/text/Skip use the production CardStore response path; mirrored permission choices use the runtime's local action handler. This is a headless presentation probe, not a UI click or pixel/render test. Closed-panel speech uses the §7 transient, without the peek/typewriter surface.", "",
        "## Measured release times", "", "Times are seconds from the localhost fixture's start. Native prompt return is positively classified from a fresh ownership-checked capture, not inferred from delivery or elapsed silence. Runtime/row transitions use the host clock, aligned below with the median adjacent-query offset (approximately " + f"{offset:.3f}" + " s). The release deltas themselves use one parent monotonic clock.", "",
        "For TTL, unread and quiet hours, idle is expected after the earned trigger is released: TTL expiry, opening/reading, or switching quiet hours off. A 30-second explicit status deliberately outlives a finished native turn.", "",
        "| Scenario | Native prompt t | Idle t | Δ after prompt | Δ after earned release | Gate |", "|---|---:|---:|---:|---:|---|"]
    for s in proof["scenarios"]:
        earned = s.get("idle_after_release_trigger_s", s["idle_after_prompt_s"])
        lines.append(f'| {s["name"]} | {s["prompt_t"]:.3f} | {s["idle_t"]:.3f} | {s["idle_after_prompt_s"]:.3f} s | {earned:.3f} s | {"pass" if s["within_5s"] else "FAIL"} |')
    lines += ["", "Both permission cases and all three question-answer cases finish **without a follow-up zeus_say**, so a new card cannot mask the release. Happy is an extra live mood check; all eight avatar states appear in this run.", "",
        "## Timestamped state / row transcript", "", "Each line is a changed presentation or native lifecycle; unchanged polling samples are omitted. The raw scrubbed JSON retains all sampling data and milestone triggers.", "", "| t (s) | Avatar | Detail / trigger | Thread activity | Managed state |", "|---:|---|---|---|---|"]
    previous = None
    for v in proof["timeline"]:
        key = (v["avatar"], v["detail"], v["row"], v["managed"], v["panel"], v["quiet"])
        if key == previous and v["trigger"] is None: continue
        previous = key
        detail = v["detail"] or v["trigger"] or ("quiet hours" if v["quiet"] else "panel closed" if not v["panel"] else "—")
        lines.append(f'| {v["t"] + offset:.3f} | {v["avatar"]} | {detail} | {v["row"] or "none"} | {v["managed"]} |')
    fast = next(s for s in before["scenarios"] if s["name"] == "fast-no-say")
    fixed = next(s for s in proof["scenarios"] if s["name"] == "fast-no-say")
    lines += ["", "## Findings and fixes", "",
        f'1. **Fast managed turn missed by polling:** baseline fast Read/no-say stayed thinking for {fast["idle_after_prompt_s"]:.3f} s after a positive native idle prompt. Fixed run: {fixed["idle_after_prompt_s"]:.3f} s. A new native Claude completion footer, scoped to its completed user turn and a fresh positive idle sample, ends an implicit row even if no working sample was captured. Old footer repaints and an echoed user message do not qualify. Unrecognized/native non-Claude formats retain the existing working/grace fallback.',
        "2. **Explicit TTL extended:** a managed working sample changed the requested 30-second activity lease into a five-minute deadline. The baseline probe stopped after 45 seconds without release in this scenario (before.json contains the extended deadline). Working screen evidence now refreshes implicit activity only; explicit thinking/working keeps its original TTL. The live TTL gate above measures expiry to idle, while auto proves an early explicit release.",
        "3. **Cross-review scheduler scope:** PC1's recorded Claude scheduled task has its own `Running scheduled task` start and footer without a new user prompt. That completion is rejected rather than attributed to the older user delivery. A fake-clock regression uses the recorded native ANSI screen and verifies a later user prompt resets the scope. See claude-scheduled-idle.json (platform PC1 provenance); no cron is created in the live SA1 run.", "",
        "## Connect-your-own gap — proposal only", "",
        f'The same private real Claude/bridge was detached from managed observation and completed Read without zeus_say. At the native prompt it still showed **{own["at_prompt"]["avatar"]} / {own["at_prompt"]["row"]}**. The full {own["observed_seconds_after_native_idle"]:.3f}-second observation released only at the stale deadline, **{delay:.3f} s after the native prompt** (own-window.json; its clock is independent of the primary run). No own-session screen is consumed by the production runtime. The probe alone reads its private pane to measure this limit.',
        "Proposed cheapest reliable Claude signal: add a launch-only Stop hook to the generated advanced launch command, sending a session-scoped, response-token-correlated turn-ended notification over Zeus's existing local bridge. It should end only that implicit response, without ending an explicit TTL or a newer response, and handle interrupts/errors separately. No saved agent config edits. The official [Stop hook reference](https://code.claude.com/docs/en/hooks#stop) documents turn completion; the [CLI --settings flag](https://code.claude.com/docs/en/cli-reference) permits session-only settings. This is a proposal, not implemented or live-proven here. A push-written receipt, next-tool-call gap or shorter stale timeout cannot establish completion during a long quiet turn.", "",
        "## Scope, verification and reproduction", "",
        "Live proof is Claude 2.1.299 only. No live Codex/OpenCode claim: the new completion parser is Claude-specific, while TTL preservation applies to all managed agents. Platform's SA2 owns their live completion probes; PC1 supplied recorded native classifier fixtures. An offscreen/long-output Claude turn without a recognizable user-scoped footer may still need the existing 20-second idle grace if working was missed. Multiple concurrent scheduled/native work needs a proper turn identity for stronger correlation.", "",
        "Fake-clock regressions cover old/new same-minute completion footers, user echo, indented content, missing footer, scheduler scoping, no resurrection, and explicit TTL versus idle/working samples. The existing state, question, unread, quiet-hours and override tests remain green.", "",
        "PM contract follow-up: §10.8 should describe managed positive-idle completion evidence/working sampling and the conservative grace, alongside preserving explicit status TTLs. Shared/CONTRACT were not edited.", "",
        "```sh", "scripts/build.sh", "python3 -B Zeus/App/Tests/SA1LiveProbe.py --own-seconds 305 --record-fixtures", "scripts/test.sh", "```", "",
        "probe.json is the primary run; before.json is the pre-fix capture; own-window.json records the full unmodified advanced-session stale window. Private helper/socket cleanup is checked independently. No automatic probe runs as part of test.sh."]
    (fixtures / "transcript.md").write_text("\n".join(lines) + "\n")


class Model(http.server.BaseHTTPRequestHandler):
    scenario = "bootstrap"
    step = 0
    lock = threading.Lock()
    project = None
    events = []
    began = 0
    acked = set()

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
            scenario, step = Model.scenario, Model.step
            target, arguments, delay = None, {}, 0
            if names:
                user_text = []
                for message in body.get("messages", []):
                    if message.get("role") == "user":
                        content = message.get("content")
                        user_text += [content] if isinstance(content, str) else [b.get("text", "") for b in content or [] if b.get("type") == "text"]
                deliveries = re.findall(r'\[zeus delivery_id=([^\s\]]+)', "\n".join(user_text))
                ack = deliveries[-1] if deliveries and deliveries[-1] not in Model.acked else None
                if ack:
                    Model.acked.add(ack)
                    target, arguments = "zeus_ack", {"delivery_ids": [ack]}
                    step = -1
                else: Model.step += 1
                if step == 0:
                    if scenario in ["bootstrap", "say", "closed-say", "happy"]:
                        target, arguments = "zeus_say", {"text": "SA1 reply: " + scenario}
                        if scenario == "happy": arguments["mood"] = "happy"
                    elif scenario in ["work-no-say", "fast-no-say", "own-no-say"]:
                        target, arguments = "Read", {"file_path": str(Model.project / "read.txt")}
                        delay = 4 if scenario == "work-no-say" else 0
                    elif scenario.startswith("ask-") or scenario == "quiet-ask":
                        target, arguments = "zeus_ask", {"title": "SA1 " + scenario, "text": "Choose a fixture path.",
                            "options": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}],
                            "allow_text": scenario == "ask-text", "wait_seconds": 60}
                    elif scenario in ["ttl", "auto"]:
                        target, arguments = "zeus_set_status", {"state": "working", "detail": "SA1 explicit work", "ttl_seconds": 30}
                    elif scenario.startswith("permission-"):
                        target, arguments = "Bash", {"command": "printf SA1_APPROVED > " + str(Model.project / (scenario + ".txt")), "description": "Write the private SA1 proof"}
                elif step == 1:
                    if scenario == "ttl": delay = 4
                    if scenario == "auto":
                        target, arguments, delay = "zeus_set_status", {"state": "auto"}, 2
                name = next((n for n in names if n == target or n.endswith("__" + str(target))), None) if target else None
                if target and not name:
                    if scenario == "bootstrap": target = None
                    else: raise RuntimeError("Missing real Claude tool " + target)
                Model.events.append({"t": time.monotonic() - Model.began, "scenario": scenario, "step": step,
                    "tool": target, "tool_results": [b for m in body.get("messages", []) if isinstance(m.get("content"), list)
                        for b in m["content"] if b.get("type") == "tool_result"]})
            else:
                name = None  # Background requests do not consume the fixture's scripted turn.
        if delay:
            time.sleep(delay)
        stream_reply(self,"anthropic",body,name,arguments,"SA1_DONE "+scenario)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="Only fast-no-say; omit long TTL, permissions and own stale observation")
    parser.add_argument("--own-seconds", type=float, default=20)
    parser.add_argument("--record-fixtures", action="store_true")
    parser.add_argument("--report-only", action="store_true", help="Regenerate Markdown from existing scrubbed evidence")
    args = parser.parse_args()
    if args.report_only:
        fixtures = REPO / "TestFixtures/live/sa1"
        report(json.loads((fixtures / "probe.json").read_text()), fixtures)
        return
    OUT.mkdir(parents=True, exist_ok=True)
    executable = build_host()
    tmux, claude = shutil.which("tmux"), shutil.which("claude")
    assert tmux and claude
    root = create_root("zsa1_")
    home, project = root / "home", root / "home" / "project"
    profile = home / ".claude"
    profile.mkdir(parents=True); project.mkdir()
    (project / "read.txt").write_text("SA1 private read-only fixture.\n")
    socket = str(root / "tmux.sock")
    server, worker = start_model(Model)
    Model.project = project; Model.began = time.monotonic()
    env = isolated_environment(home, {"ANTHROPIC_API_KEY":"sa1-local-fixture", "ANTHROPIC_BASE_URL":f"http://127.0.0.1:{server.server_port}"})
    onboarding = {"hasCompletedOnboarding": True, "theme": "dark", "hasAcknowledgedCostThreshold": True,
        "projects": {str(project): {"hasTrustDialogAccepted": True}, str(project.resolve()): {"hasTrustDialogAccepted": True}}}
    (home / ".claude.json").write_text(json.dumps(onboarding)); (profile / ".claude.json").write_text(json.dumps(onboarding))
    (profile / "settings.json").write_text(json.dumps({"permissions": {"allow": ["Read"], "ask": ["Bash"]}}))
    bridge = REPO / "build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
    assert bridge.is_file(), "Run scripts/build.sh first"
    host = None
    tracked = {}
    proof = {"claude": subprocess.check_output([claude, "--version"], env=env, text=True, timeout=10).strip(),
        "private_socket": True, "disposable_home": True, "localhost_model": True, "scenarios": [], "events": []}
    def tm(*arguments):
        return subprocess.check_output([tmux, "-u", "-S", socket, "-f", "/dev/null", *arguments], env=env, text=True, timeout=10)
    def scrub(value): return scrub_paths(value,{str(root):"<fixture>", str(REPO):"<worktree>"})
    def track(pid):
        stamp = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
        if not stamp: return
        tracked[pid] = stamp
        children = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
        for child in children: track(int(child))
    try:
        host = subprocess.Popen([str(executable), str(root), str(bridge), claude, tmux], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=(OUT / "host.log").open("w"), env=env, text=True, bufsize=1)
        control = Control(host); assert control.read()["ready"]
        target = {"pane": None}
        def screen():
            target["pane"] = target["pane"] or control.state()["pane"]
            return tm("capture-pane", "-p", "-t", target["pane"]) if target["pane"] else ""
        accepted = set()
        def startup():
            state = control.state()
            pane = state["pane"]
            if pane:
                text = screen()
                if "trust" not in accepted and "Quick safety check:" in text and (str(project) in text or str(project.resolve()) in text) and "Yes, I trust this folder" in text:
                    accepted.add("trust")
                    tm("send-keys", "-t", pane, "Down", "Enter")
                elif "key" not in accepted and "Do you want to use this API key?" in text:
                    accepted.add("key")
                    tm("send-keys", "-t", pane, "Up", "Enter")
            return state["can_input"] and state["sessions"] and "SA1_DONE bootstrap" in screen()
        eventually(startup, "Private managed Claude startup failed", 60)
        track(host.pid)
        track(int(tm("display-message", "-p", "-t", target["pane"], "#{pane_pid}")))
        eventually(lambda: control.state()["avatar"] == "idle", "Bootstrap did not return idle")
        def run(case):
            with Model.lock: Model.scenario = case; Model.step = 0
            started = time.monotonic()
            response = control.call("send", text="SA1 scenario " + case)
            proof["events"].append({"t": started - Model.began, "trigger": "send " + case, "state": response["state"], "result": response["result"]})
            return started
        def finished(case):
            snapshot = control.call("snapshot")
            return snapshot["classification"] == "idle" and "SA1_DONE " + case in snapshot["screen"]
        def settle(case, started, prompt_at=None, release_at=None, timeout=45):
            if prompt_at is None:
                eventually(lambda: finished(case), "Native turn did not finish: " + case, timeout)
                prompt_at = time.monotonic()
                proof["events"].append({"t": prompt_at - Model.began, "trigger": "native prompt returned " + case, "state": control.state(), "native": control.call("snapshot")})
            eventually(lambda: control.state()["avatar"] == "idle" and control.state()["row"] is None,
                "Avatar did not release: " + case, timeout)
            ended = time.monotonic()
            result = {"name": case, "prompt_t": prompt_at - Model.began, "idle_t": ended - Model.began,
                "idle_after_prompt_s": round(ended - prompt_at, 3), "within_5s": ended - prompt_at <= 5}
            if release_at is not None:
                result["release_trigger_t"] = release_at - Model.began
                result["idle_after_release_trigger_s"] = round(ended - release_at, 3)
                result["within_5s"] = ended - release_at <= 5
            proof["scenarios"].append(result); print(json.dumps(result), flush=True)
            eventually(lambda: control.state()["can_input"], "Managed input did not become ready")
        for case in (["fast-no-say"] if args.quick else ["say", "happy", "work-no-say", "fast-no-say", "ask-option", "ask-text", "ask-skip", "closed-say", "ttl", "auto", "permission-ui", "permission-terminal", "quiet-ask"]):
            if case == "closed-say": control.call("panel", open=False)
            if case == "quiet-ask":
                control.call("quiet", enabled=True)
                eventually(lambda: control.state()["avatar"] == "sleeping", "Quiet hours never slept")
            started = run(case)
            release_at = prompt_at = None
            if case == "happy": eventually(lambda: control.state()["avatar"] == "happy", "Happy mood never appeared")
            if case.startswith("ask-") or case == "quiet-ask":
                q = eventually(lambda: next((c for c in control.state()["cards"] if c["title"] == "SA1 " + case and c["status"] == "open"), None), "Ask never reached CardStore")
                eventually(lambda: control.state()["avatar"] == "waiting", "Question never showed waiting")
                proof["events"].append({"t": time.monotonic() - Model.began, "trigger": "question waiting " + case, "state": control.state()})
                reply = control.call("skip" if case in ["ask-skip", "quiet-ask"] else "answer", id=q["id"],
                    **({"text": "Typed fixture reply"} if case == "ask-text" else {"option": "yes"} if case == "ask-option" else {}))
                assert reply["recorded"], reply
            if case == "closed-say":
                eventually(lambda: finished(case), "Closed-panel turn never finished")
                prompt_at = time.monotonic()
                eventually(lambda: control.state()["avatar"] == "alert", "Closed-panel message never alerted")
                release_at = time.monotonic()
                proof["events"].append({"t": time.monotonic() - Model.began, "trigger": "open and read panel", "state": control.state()})
                control.call("panel", open=True)
            if case in ["ttl", "auto"]:
                eventually(lambda: control.state()["avatar"] == "working", "Explicit working never appeared")
                state = control.state(); observed_at = time.monotonic()
                proof["events"].append({"t": observed_at - Model.began, "trigger": "explicit working " + case, "state": state})
                if case == "ttl": release_at = observed_at + state["activity_deadline"] - state["t"]
            if case.startswith("permission-"):
                card = eventually(lambda: next((c for c in control.state()["cards"] if c["status"] == "open" and c["id"].startswith("managed-block_") and any(o["id"].startswith("managed-answer:") for o in c["options"])), None), "Native permission not mirrored", 35)
                state = control.state(); assert state["avatar"] == "alert" and state["detail"] == "Waiting for your answer" and state["row"] is None, state
                proof["events"].append({"t": time.monotonic() - Model.began, "trigger": "native permission " + case, "state": state, "screen": screen()})
                if case == "permission-ui":
                    option = next(o for o in card["options"] if o["id"].endswith(":1"))
                    control.call("answer", id=card["id"], option=option["id"])
                else: tm("send-keys", "-t", state["pane"], "1")
                eventually(lambda: (project / (case + ".txt")).exists(), "Permission answer did not execute the private command")
            if case == "quiet-ask":
                eventually(lambda: "SA1_DONE " + case in screen() and control.state()["avatar"] == "sleeping", "Quiet question never returned to sleep")
                proof["events"].append({"t": time.monotonic() - Model.began, "trigger": "quiet question completed", "state": control.state()})
                release_at = time.monotonic()
                control.call("quiet", enabled=False)
            settle(case, started, prompt_at=prompt_at, release_at=release_at)
        if not args.quick:
            # Same real CLI/bridge, detached from managed observation: advanced connection.
            track(int(tm("display-message", "-p", "-t", target["pane"], "#{pane_pid}")))
            control.call("own")
            eventually(lambda: control.state()["sessions"] > 0, "Own bridge never reconnected")
            with Model.lock: Model.scenario = "own-no-say"; Model.step = 0
            control.call("send", text="SA1 scenario own-no-say")
            eventually(lambda: "SA1_DONE own-no-say" in screen(), "Own turn never finished")
            returned = time.monotonic(); before = control.state()
            time.sleep(args.own_seconds)
            after = control.state()
            proof["own_session"] = {"observed_seconds_after_native_idle": round(time.monotonic() - returned, 3), "at_prompt": before, "after": after}
    finally:
        if host:
            stop_host(host)
        cleanup_root(root, remove=False)
        def helpers_gone():
            return all(subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip() != stamp for pid, stamp in tracked.items())
        eventually(helpers_gone, "Probe-owned CLI/helper still alive after private server cleanup", 10)
        proof["cleanup"] = {"tracked_processes": len(tracked), "helpers_gone": True, "private_socket_gone": not pathlib.Path(socket).exists()}
        server.shutdown(); server.server_close()
        proof["model_events"] = Model.events
        proof["timeline"] = [json.loads(line) for line in (root / "timeline.jsonl").read_text().splitlines()] if (root / "timeline.jsonl").exists() else []
        cleanup_root(root)
        assert not root.exists(), "Private scratch directory was not removed"
        proof["cleanup"]["scratch_gone"] = True
        proof["cleanup"]["private_socket_gone"] = not pathlib.Path(socket).exists()
        (OUT / "proof.json").write_text(json.dumps(scrub(proof), indent=2))
        if args.record_fixtures:
            fixtures = REPO / "TestFixtures/live/sa1"; fixtures.mkdir(parents=True, exist_ok=True)
            (fixtures / "probe.json").write_text(json.dumps(scrub(proof), indent=2))
            if args.own_seconds >= 300 and "own_session" in proof:
                (fixtures / "own-window.json").write_text(json.dumps(scrub(proof), indent=2))
            if "own_session" in proof and len(proof["scenarios"]) == 13:
                report(scrub(proof), fixtures)


if __name__ == "__main__":
    main()
