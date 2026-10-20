#!/usr/bin/env python3
"""Real Claude + production headless runtime; private tmux/HOME and localhost model.

Run from the worktree root after scripts/build.sh: python3 -B Zeus/App/Tests/Runtime/AC1LiveProbe.py
LV1: add --scenario lv1 (or lv1-learnings / lv1-skipped) for live summary/Skip checks.
Writes under build/ and its own /tmp scratch; --record-fixtures also writes scrubbed
LV1 evidence in TestFixtures/live/. Never reads the user's agent configs/credentials.
"""
from LiveSupport import Model, HostControl, eventually, output_dir, create_root, isolated_environment, start_model, finish_host_build, host_package, scrub_paths, cleanup_root, stop_host
import argparse
import http.server
import json
import os
import pathlib
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[4]
OUT = output_dir("ac1-live")
OUT.mkdir(parents=True, exist_ok=True)
LV1_ROOTS = []


def build_host():
    package = host_package(OUT, "ac1")
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
    return finish_host_build(OUT, package)




def ac1_main():
    executable = build_host()
    tmux, claude = shutil.which("tmux"), shutil.which("claude")
    assert tmux and claude, "tmux and Claude must be installed"
    root = create_root("zac1_")
    home, project = root / "home", root / "home" / "project"
    profile = home / ".claude"
    profile.mkdir(parents=True); project.mkdir()
    socket = str(root / "tmux.sock")
    server, thread = start_model(Model)
    env = isolated_environment(home, {"ZEUS_AC1_HOST": "1"})
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
        cleanup_root(root, remove=False)
        if host:
            stop_host(host)
        server.shutdown(); server.server_close(); thread.join(timeout=2)
        cleanup_root(root)







def frames(path, direction=None):
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue  # Writer may still be finishing its current frame.
        if direction is None or record["direction"] == direction:
            records.append(record["frame"])
    return records


def tool_results(path):
    calls = {frame["id"]: frame["params"]["name"] for frame in frames(path, "agent") if frame.get("method") == "tools/call"}
    return [(calls[frame["id"]], frame["result"]) for frame in frames(path, "bridge") if frame.get("id") in calls and "result" in frame]


def notification(path, method):
    return next((frame for frame in frames(path, "bridge") if frame.get("method") == method), None)


# Transparent stdio relay: logs only this private fixture's frames and forwards the
# exact bytes to/from the real agent. The child is the branch-built zeus-mcp.
MCP_RELAY = r'''
import json, pathlib, subprocess, sys, threading
trace = pathlib.Path(sys.argv[1])
err = trace.with_suffix('.stderr').open('wb')
child = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err)
lock = threading.Lock()
def record(direction, line):
    try: value = json.loads(line)
    except (ValueError, UnicodeDecodeError): return
    with lock:
        with trace.open('a') as log: log.write(json.dumps({'direction':direction,'frame':value})+'\n')
def inputs():
    try:
        for line in sys.stdin.buffer:
            record('agent',line); child.stdin.write(line); child.stdin.flush()
    except (BrokenPipeError,OSError): pass
    finally:
        try: child.stdin.close()
        except OSError: pass
threading.Thread(target=inputs,daemon=True).start()
try:
    for line in child.stdout:
        record('bridge',line); sys.stdout.buffer.write(line); sys.stdout.buffer.flush()
finally:
    if child.poll() is None: child.terminate()
    try: child.wait(timeout=3)
    except subprocess.TimeoutExpired: child.kill(); child.wait()
    err.close()
'''


def lv1_case(executable, case):
    out = OUT / case
    out.mkdir(parents=True, exist_ok=True)
    root = create_root("zlv1_")
    LV1_ROOTS.append(root)
    (out / "proof.json").unlink(missing_ok=True)
    home, project = root / "home", root / "home" / "project"
    profile = home / ".claude"
    profile.mkdir(parents=True); project.mkdir()
    tmux, claude = shutil.which("tmux"), shutil.which("claude")
    assert tmux and claude
    tmux_socket = str(root / "tmux.sock")
    trace = root / "mcp-trace.jsonl"
    relay = root / "relay.py"; relay.write_text(MCP_RELAY)
    env = isolated_environment(home, {"ZEUS_LV1_HOST": "1"})
    host = None
    server = None
    pending_release = threading.Event()
    observed = {}
    Model.stage = 0; Model.results = []; Model.requests = []
    try:
        host = subprocess.Popen([str(executable), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=(out / "host.log").open("w"), env=env, text=True, bufsize=1)
        control = HostControl(host)
        assert control.read()["ready"]

        def action(body):
            results = [block for message in body.get("messages", []) if isinstance(message.get("content"), list)
                for block in message["content"] if block.get("type") == "tool_result"]
            if case == "learnings":
                if Model.stage == 2:
                    control.call("learning_add", id="lv1-new-moment", text="Fixture new moment after connection.")
                    event = eventually(lambda: notification(trace, "notifications/zeus/learning"), "No learning announcement")
                    assert event["params"] == {"id": "lv1-new-moment", "kind": "moment", "text": "Fixture new moment after connection."}, event
                    before_disable = control.call("state")
                    assert before_disable["unread"] == ["lv1-new-moment"], before_disable
                    assert before_disable["readThrough"] == ["lv1-moment"], before_disable
                    observed["notification"] = event
                    observed["announcement_does_not_consume"] = True
                    control.call("learning_enabled", enabled=False)
                return ("zeus_get_learnings", {}) if Model.stage < 3 else (None, {})
            if Model.stage == 0:
                return "zeus_ask", {"title": "Choose a path", "text": "Should we keep going?", "options": [{"id": "continue", "label": "Continue"}, {"id": "later", "label": "Later"}], "wait_seconds": 30}
            if case == "skip-channel" and Model.stage == 1:
                assert results, "Pending ask result must reach the model before Skip"
                observed["pending_reached_model"] = True
                if not pending_release.wait(timeout=45):
                    raise TimeoutError("Pending channel proof was not released")
            if case == "skip-tmux":
                # JSON escaping is not part of Terminal input; inspect text blocks directly.
                texts = [message.get("content") for message in body.get("messages", []) if isinstance(message.get("content"), str)]
                texts += [block.get("text", "") for message in body.get("messages", []) if isinstance(message.get("content"), list) for block in message["content"] if block.get("type") == "text"]
                envelope = next((text for text in texts if '[zeus delivery_id=' in text and 'The user skipped "Choose a path".' in text), None)
                if envelope and not observed.get("tmux_model_text"):
                    observed["tmux_model_text"] = envelope
                    match = re.search(r'\[zeus delivery_id=([^\s\]]+) card_id=([^\s\]]+)\]', envelope)
                    assert match, envelope
                    return "zeus_ack", {"delivery_ids": [match.group(1)]}
            return None, {}

        Model.action = action
        server, thread = start_model(Model)
        env.update({"CLAUDE_CONFIG_DIR": str(profile), "ANTHROPIC_API_KEY": "lv1-local-fixture", "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1", "ENABLE_TOOL_SEARCH": "false"})
        onboarding = {"hasCompletedOnboarding": True, "theme": "dark", "hasAcknowledgedCostThreshold": True, "projects": {str(project): {"hasTrustDialogAccepted": True}}}
        (home / ".claude.json").write_text(json.dumps(onboarding)); (profile / ".claude.json").write_text(json.dumps(onboarding))
        version = subprocess.check_output([claude, "--version"], env=env, text=True, timeout=10).strip()
        bridge = REPO / "build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
        assert bridge.is_file()
        config = root / "mcp.json"
        config.write_text(json.dumps({"mcpServers": {"zeus": {"command": sys.executable, "args": [str(relay), str(trace), str(bridge), "--agent", "claude", "--socket", str(root / "bridge.sock")]}}}))
        prompt = "LV1 private localhost fixture. Use the Zeus tools requested by the user."
        argv = [claude, "--model", "claude-haiku-4-5", "--permission-mode", "manual", "--mcp-config", str(config), "--allowedTools", "mcp__zeus__zeus_get_learnings,mcp__zeus__zeus_ask,mcp__zeus__zeus_ack"]
        if case != "skip-tmux":
            argv += ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        launcher = root / "launch.py"
        launcher.write_text("import json,os,signal,subprocess,pathlib,threading\n" + f"argv=json.loads({json.dumps(json.dumps(argv))})\nenv=json.loads({json.dumps(json.dumps(env))})\n" + "env.update({k:os.environ[k] for k in ['TMUX','TMUX_PANE'] if k in os.environ})\n" +
            "child=None\ndef stop(*_):\n if child is not None and child.poll() is None:\n  os.killpg(child.pid,signal.SIGTERM)\n  def force():\n   if child.poll() is None: os.killpg(child.pid,signal.SIGKILL)\n  timer=threading.Timer(3,force);timer.daemon=True;timer.start()\nsignal.signal(signal.SIGHUP,stop);signal.signal(signal.SIGTERM,stop)\n" +
            ("child=subprocess.Popen(argv,env=env,start_new_session=True)\n" if case == "skip-tmux" else f"log=open({str(out / 'claude.jsonl')!r},'w')\nchild=subprocess.Popen(argv,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)\n") +
            f"pathlib.Path({str(root / 'agent.pid')!r}).write_text(str(child.pid))\nstatus=child.wait()\npathlib.Path({str(root / 'exit')!r}).write_text(str(status))\n")
        def tm(*args):
            return subprocess.check_output([tmux, "-u", "-S", tmux_socket, "-f", "/dev/null", *args], env=env, text=True, timeout=10)
        tm("new-session", "-d", "-s", "lv1", "-x", "120", "-y", "40", "-c", str(project), "/bin/sleep", "120")
        tm("set-option", "-w", "-t", "lv1", "remain-on-exit", "on")
        tm("respawn-pane", "-k", "-t", "lv1:0.0", "-c", str(project), sys.executable, str(launcher))
        if case == "skip-tmux":
            # Accept only this disposable folder/fake API-key onboarding, never a tool or channel permission.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                screen = tm("capture-pane", "-p", "-t", "lv1")
                if "Quick safety check:" in screen and str(project) in screen and "Yes, I trust this folder" in screen:
                    tm("send-keys", "-t", "lv1", "Down", "Enter")
                elif "Do you want to use this API key?" in screen:
                    tm("send-keys", "-t", "lv1", "Up", "Enter")
                if any("tools" in frame.get("result", {}) for frame in frames(trace, "bridge")): break
                time.sleep(.1)
            assert any("tools" in frame.get("result", {}) for frame in frames(trace, "bridge")), "Interactive Claude did not register MCP tools"
            # Interactive launch does not wait for MCP initialization before an initial
            # positional prompt. Send the fixture prompt only after registration.
            eventually(lambda: "❯" in tm("capture-pane", "-p", "-t", "lv1"), "Claude composer missing")
            tm("send-keys", "-l", "-t", "lv1", prompt)
            tm("send-keys", "-t", "lv1", "Enter")
        if case.startswith("skip-"):
            card = eventually(lambda: next((card for card in control.call("state")["cards"] if card["status"] == "open"), None), "Real agent never asked a question")
            if case == "skip-waiter":
                assert control.call("state")["waiters"] == 1
            else:
                result = eventually(lambda: next((result for name, result in tool_results(trace) if name == "zeus_ask"), None), "Thirty-second ask never returned pending", timeout=45)
                assert result["structuredContent"] == {"status": "pending", "card_id": card["id"]}, result
            if case == "skip-tmux":
                control.call("routing", method="tmux")
                # The next native turn must start from the live idle composer.
                eventually(lambda: "LV1_PROVED" in tm("capture-pane", "-p", "-t", "lv1"), "Claude did not finish its first turn")
                (out / "before.txt").write_text(tm("capture-pane", "-p", "-e", "-t", "lv1"))
            state = control.call("state")
            assert state["sessions"][0]["channel"] and state["sessions"][0]["learningNotifications"], state
            assert control.call("skip", id=card["id"])["recorded"]
            if case == "skip-channel":
                event = eventually(lambda: notification(trace, "notifications/claude/channel"), "No late-skip channel notification")
                assert event["params"]["content"] == 'The user skipped "Choose a path".', event
                assert event["params"]["meta"]["kind"] == "skipped", event
                assert event["params"]["meta"]["card_id"] == card["id"] and "option_id" not in event["params"]["meta"], event
                observed["channel_notification"] = event
                pending_release.set()
            elif case == "skip-tmux":
                eventually(lambda: observed.get("tmux_model_text"), "Skip envelope was not submitted to real Claude", timeout=45)
                ack = eventually(lambda: next((result for name, result in tool_results(trace) if name == "zeus_ack"), None), "Real Claude did not ack the skipped text")
                assert not ack.get("isError", False), ack
                delivery = eventually(lambda: next((record for record in control.call("state")["deliveries"] if record["acked"]), None), "Skip ack did not commit")
                assert delivery["attempts"] == 1, delivery
                expected = f'[zeus delivery_id={delivery["id"]} card_id={card["id"]}] The user skipped "Choose a path". (call zeus_ack with this delivery_id)'
                assert observed["tmux_model_text"] == expected, observed
                assert notification(trace, "notifications/claude/channel") is None
                observed["attempts"] = 1; observed["acked"] = True
        if case != "skip-tmux":
            eventually(lambda: (root / "exit").exists(), "Claude did not finish the fixture", timeout=45)
            assert (root / "exit").read_text() == "0"
        results = tool_results(trace)
        if case == "learnings":
            replies = [result["structuredContent"]["learnings"] for name, result in results if name == "zeus_get_learnings"]
            assert len(replies) == 3 and [item["id"] for item in replies[0]] == ["lv1-digest", "lv1-moment"], replies
            assert [item["kind"] for item in replies[0]] == ["digest", "moment"], replies
            assert replies[1:] == [[], []], replies
            observed["tool_results"] = replies
            state = control.call("state")
            assert state["unread"] == ["lv1-new-moment"] and state["readThrough"] == ["lv1-moment"], state
            observed["unread_after_disabled_tool"] = state["unread"]
        elif case == "skip-waiter":
            reply = next(result for name, result in results if name == "zeus_ask")
            assert reply["structuredContent"] == {"status": "skipped", "card_id": card["id"]}, reply
            assert json.loads(reply["content"][0]["text"]) == reply["structuredContent"]
            # Claude appends its own system-reminder after the tool's JSON text.
            assert any(json.JSONDecoder().raw_decode(block["content"])[0] == reply["structuredContent"] for block in Model.results), "The skipped result did not reach Claude's model request"
            assert control.call("state")["deliveries"] == []
            observed["tool_result"] = reply["structuredContent"]
        (out / "mcp-trace.jsonl").write_text(trace.read_text())
        (out / "model-requests.json").write_text(json.dumps(Model.requests, indent=2))
        (out / "state.json").write_text(json.dumps(control.call("state"), indent=2))
        summary = dict(case=case, claude=version, private_socket=True, disposable_home=True, localhost_model=True, pane="120x40", **observed)
        (out / "proof.json").write_text(json.dumps(summary, indent=2)); print(json.dumps(summary), flush=True)
        return summary
    finally:
        pending_release.set()
        if (root / "tmux.sock").exists():
            capture = subprocess.run([tmux, "-S", tmux_socket, "capture-pane", "-p", "-e", "-t", "lv1"], env=env, capture_output=True, text=True, timeout=10)
            (out / "final-pane.txt").write_text(capture.stdout)
        if trace.exists(): (out / "mcp-trace.jsonl").write_text(trace.read_text())
        (out / "model-requests.json").write_text(json.dumps(Model.requests, indent=2))
        cleanup_root(root, remove=False)
        if (root / "agent.pid").exists():
            eventually(lambda: (root / "exit").exists(), "Probe agent failed to exit after private tmux shutdown", timeout=6)
        if host:
            stop_host(host)
        if server:
            server.shutdown(); server.server_close()
        Model.action = None
        cleanup_root(root)
        assert not root.exists(), "Probe scratch cleanup failed"


def record_lv1(proofs):
    """Persist only synthetic payloads, normalizing opaque delivery/card identities."""
    def scrub(value):
        if isinstance(value, dict): return {key: scrub(item) for key, item in value.items()}
        if isinstance(value, list): return [scrub(item) for item in value]
        if isinstance(value, str): return re.sub(r'\bd_[a-z0-9]{8}\b', 'd_fixture', re.sub(r'\bc_[a-z0-9]{8}\b', 'c_fixture', value))
        return value
    by_case = {proof["case"]: scrub(proof) for proof in proofs}
    target = REPO / "TestFixtures/live"
    if "learnings" in by_case:
        result = by_case["learnings"]
        result["verification"] = "Real Claude MCP tool results and transparent stdio capture from branch-built zeus-mcp and production headless runtime. Synthetic LearningsProviding only; announcements forwarded to the real agent do not consume unread state. All probe helpers and scratch cleaned."
        (target / "lv1-learnings.json").write_text(json.dumps(result, indent=2) + "\n")
    if all(case in by_case for case in ["skip-waiter", "skip-channel", "skip-tmux"]):
        result = {"ask": {"title": "Choose a path", "text": "Should we keep going?", "options": [{"id": "continue", "label": "Continue"}, {"id": "later", "label": "Later"}], "wait_seconds": 30},
            "cases": [by_case[case] for case in ["skip-waiter", "skip-channel", "skip-tmux"]],
            "verification": "Real Claude calls zeus_ask. Host records CardResponse(skipped:true). Synchronous result reaches Claude's model; late channel frame is captured on real agent MCP stdio (subscription channel enablement is not claimed with a synthetic API key); tmux envelope reaches real interactive Claude's model and zeus_ack commits at attempt 1. All probe helpers and scratch cleaned."}
        (target / "lv1-skipped.json").write_text(json.dumps(result, indent=2) + "\n")


def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true", help="Run the shortest LV1 learning scenario")
    parser.add_argument("--scenario", choices=["ac1", "lv1", "lv1-learnings", "lv1-skipped", "lv1-tmux"], default="ac1")
    parser.add_argument("--record-fixtures", action="store_true", help="Write scrubbed LV1 JSON evidence after successful full scenarios")
    args = parser.parse_args()
    if args.record_fixtures and args.scenario in ["ac1", "lv1-tmux"]:
        parser.error("--record-fixtures requires lv1, lv1-learnings or lv1-skipped")
    if args.scenario == "ac1":
        ac1_main()
        return
    OUT = output_dir("lv1-live"); OUT.mkdir(parents=True, exist_ok=True)
    executable = build_host()
    cases = ["learnings", "skip-waiter", "skip-channel", "skip-tmux"] if args.scenario == "lv1" else ["learnings"] if args.scenario == "lv1-learnings" else ["skip-tmux"] if args.scenario == "lv1-tmux" else ["skip-waiter", "skip-channel", "skip-tmux"]
    if args.quick and args.scenario == "lv1": cases = ["learnings"]
    proofs = [lv1_case(executable, case) for case in cases]
    def helpers_cleaned():
        processes = subprocess.check_output(["/bin/ps", "-axo", "command="], text=True)
        return not any(str(root) in line for root in LV1_ROOTS for line in processes.splitlines())
    eventually(helpers_cleaned, "Probe-owned helpers remained after cleanup", timeout=5)
    if args.record_fixtures: record_lv1(proofs)
    (OUT / "proof.json").write_text(json.dumps(proofs, indent=2))


if __name__ == "__main__":
    main()
