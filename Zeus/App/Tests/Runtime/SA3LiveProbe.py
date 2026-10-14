#!/usr/bin/env python3
"""SA3 real Connect-your-own native completion; private tmux/HOME and localhost model.

Run after build.sh. --record copies scrubbed successful/failing facts and ANSI
frames, never private profiles, to TestFixtures/live/sa3. No default tmux access.
"""
import argparse
import http.server
import sys
import shlex
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
OUT = REPO / "build/sa3-live"
OUT.mkdir(parents=True, exist_ok=True)


def build_host():
    package = OUT / "host"
    source = package / "Sources/Host"
    source.mkdir(parents=True, exist_ok=True)
    inputs = [REPO / p for p in ["Zeus/App/Tests/Runtime/SA3RuntimeHost.swift", "Zeus/Shared/AppSeams.swift", "Zeus/Settings/SetupCommands.swift",
        "Zeus/Cards/CardStore.swift", "Zeus/Cards/ThreadNotice.swift", "Zeus/Cards/AttachmentTarget.swift",
        "Zeus/Avatar/AvatarStatusModel.swift", "Zeus/Cards/ConversationActivityRow.swift"]]
    inputs += [p for area in ["Zeus/Bridge", "Zeus/Agents"] for p in (REPO / area).glob("*.swift") if p.name != "DebugSpriteFrameCounter.swift"]
    for path in inputs:
        value=path.read_text()
        if path.name=="ZeusRuntime+TurnEnded.swift":
            # Test-only observation in the copied host source. Production callback
            # and all identity/token decisions remain unchanged.
            value=value.replace("        guard let lease = prepareTurnEnded(event)", '        if let path = ProcessInfo.processInfo.environment["SA3_EVENT_LOG"], var data = try? ZeusJSON.encoder().encode(event), let file = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) { data.append(10); _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close() }\n        guard let lease = prepareTurnEnded(event)')
        (source/path.name).write_text(value)
    products = ",".join(f'.product(name: "{name}", package: "ZeusKit")' for name in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "SA3Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.executableTarget(name: "Host", dependencies: [{products}], swiftSettings: [.define("SA3_PROBE_HOST")])])\n')
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
    completions = []

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
        triggers = re.findall(r"SA3_(?:SAY|SHELL|FAST|BUSY|FOLLOWUP|DRAFT)", history)
        scenario = triggers[-1] if triggers else "bootstrap"
        ids = re.findall(r"delivery_id=(d_sa3_[a-z]+)", history)
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
            elif delivery and step == 1 and scenario in ["SA3_SAY", "SA3_FOLLOWUP"]:
                tool, args = name("zeus_say"), {"text": scenario + " native bridge reply."}
            elif delivery and step == 1:
                tool = name("exec_command" if "exec_command" in names else "bash")
                args = {"cmd": "printf SA3_SHELL_DONE"} if tool == "exec_command" else {"command": "printf SA3_SHELL_DONE", "description": "Print the isolated state fixture marker"}
            Model.steps[delivery] = step + 1
            Model.events.append({"t": time.monotonic() - Model.began, "scenario": scenario, "delivery": delivery, "step": step, "tool": tool,
                "tool_results": [m for m in messages if isinstance(m, dict) and (m.get("type") == "function_call_output" or m.get("role") == "tool")]})
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode()); self.wfile.flush()
        pause = Model.pauses.get(scenario) if delivery and step >= 2 and not tool else None
        text = "SA3_READY" if not delivery else scenario + " native turn complete."
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
            if delivery and not tool:
                Model.completions.append({"delivery":delivery,"t":time.monotonic()-Model.began})
        except (BrokenPipeError, ConnectionResetError):
            pass



from PC1LiveScreens import Pane
from AC1LiveProbe import Model as ClaudeModel, HostControl, eventually

class ClaudeCompletion(ClaudeModel):
    completed = []
    fail = False
    paused = None
    entered = None
    local = threading.local()
    finalTimes = {}
    pauseDelivery = None
    pauseEntered = threading.Event()
    pauseRelease = threading.Event()
    def do_POST(self):
        if self.path.split("?")[0].endswith("count_tokens"):
            super().do_POST(); return
        if ClaudeCompletion.fail:
            self.send_response(400); self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"invalid_request_error","message":"SA3 synthetic stopped request"}}')
            return
        ClaudeCompletion.local.delivery=None
        try:super().do_POST()
        except (BrokenPipeError,ConnectionResetError):return
        ClaudeCompletion.completed.append(time.monotonic())
        if ClaudeCompletion.local.delivery:
            ClaudeCompletion.finalTimes[ClaudeCompletion.local.delivery]=time.monotonic()

class Probe:
    def __init__(self, host, agent):
        self.agent=agent
        self.pane=Pane(agent)
        # Pane's helpers own their process group, tmux socket and profile. Move
        # the unopened namespace to this task's prefix before any launch.
        old=self.pane.root; root=pathlib.Path(tempfile.mkdtemp(prefix="zsa3_",dir="/tmp")).resolve(); root.rmdir(); old.rename(root)
        self.pane.root=root; self.pane.home=root/"home"; self.pane.project=root/"project"; self.pane.socket=str(root/"tmux.sock")
        self.pane.env={k:v.replace(str(old),str(root)) for k,v in self.pane.env.items()}
        self.pane.env.pop("OPENCODE_DISABLE_EXTERNAL_PLUGINS",None)
        self.root=root; self.frames={}; self.events=[]; self.scenarios=[]; self.began=time.monotonic()
        self.bridge=REPO/"build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
        self.log=(OUT/(agent+"-host.log")).open("w")
        (root/"wire-hooks.jsonl").write_text("");self.pane.env["SA3_EVENT_LOG"]=str(root/"wire-hooks.jsonl")
        self.host=subprocess.Popen([str(host),str(root),str(self.bridge),agent,self.pane.tmux],env=self.pane.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True)
        self.control=HostControl(self.host); self.ready=self.control.read(); self.launch=self.ready["launch"]
    def state(self):return self.control.call("state")["state"]
    def frame(self,name):
        frame=self.pane.snapshot();self.frames[name]=frame;return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",frame["screen"])
    def start(self):
        if self.agent=="claude":
            ClaudeModel.stage=0;ClaudeModel.requests=[];ClaudeModel.results=[];ClaudeModel.completion_text="SA3 native turn complete.";ClaudeCompletion.completed=[];ClaudeCompletion.fail=False;ClaudeCompletion.finalTimes={}
            def action(body):
                users=[m.get("content",[]) for m in body.get("messages",[]) if m.get("role")=="user"]
                raw=json.dumps(users); ids=re.findall(r"delivery_id=(d_sa3_[a-z]+)",raw);did=ids[-1] if ids else None
                results=[b for m in body.get("messages",[]) if isinstance(m.get("content"),list) for b in m["content"] if b.get("type")=="tool_result"]
                if did and not any(did in json.dumps(b) for b in results):return "zeus_ack",{"delivery_ids":[did]}
                if did and not any("SA3_SHELL_DONE" in json.dumps(b) for b in results):return "Bash",{"command":"printf SA3_SHELL_DONE","description":"Print private fixture marker"}
                ClaudeCompletion.local.delivery=did
                if did and did==ClaudeCompletion.pauseDelivery:
                    ClaudeCompletion.pauseEntered.set();ClaudeCompletion.pauseRelease.wait(timeout=90)
                return None,{}
            ClaudeModel.action=action
            def args(base):
                config=self.root/"mcp.json"
                # Step 1, same server definition, scoped only to this scratch launch.
                config.write_text(json.dumps({"mcpServers":{"zeus":{"command":str(self.bridge),"args":["--agent","claude","--socket",str(self.root/"bridge.sock")]}}}))
                tokens=shlex.split(self.launch)[1:]
                settings_i=tokens.index("--settings")+1
                settings=json.loads(tokens[settings_i])
                logger=self.root/"hook-log.py"
                logger.write_text('import sys,pathlib\np=pathlib.Path('+repr(str(self.root/"hook-input.jsonl"))+')\nwith p.open("a") as f:f.write(sys.stdin.read().strip()+"\\n")\n')
                for group in settings["hooks"].values():
                    for entry in group:entry["hooks"].append({"type":"command","command":shlex.quote(sys.executable)+" "+shlex.quote(str(logger)),"timeout":1})
                tokens[settings_i]=json.dumps(settings)
                return [self.pane.cli,*tokens,"--mcp-config",str(config),"--model","claude-haiku-4-5","--permission-mode","manual","--allowedTools","mcp__zeus__zeus_ack,Bash"]
            self.pane.start(ClaudeCompletion,args,lambda base:{"ANTHROPIC_API_KEY":"sa3-local-fixture","ANTHROPIC_BASE_URL":base})
        elif self.agent=="codex":
            Model.steps={};Model.events=[];Model.completions=[];Model.pauses={};Model.began=self.began
            def args(base):
                subprocess.run([self.pane.cli,"mcp","add","zeus","--",str(self.bridge),"--agent","codex","--socket",str(self.root/"bridge.sock")],env=self.pane.env,cwd=self.pane.project,check=True,capture_output=True,timeout=15)
                # The generated command creates a default tmux session. This
                # fixture already has one PRIVATE pane; use its exact Codex argv.
                tokens=shlex.split(self.launch);tokens=tokens[4:]
                assert tokens[0]=="codex",tokens
                overrides=['mcp_servers.zeus.tools.zeus_ack.approval_mode="approve"',"check_for_update_on_startup=false",'model="sa3"','model_provider="sa3"',
                    'model_providers.sa3={name="SA3 localhost",base_url="'+base+'/v1",wire_api="responses",requires_openai_auth=false}',
                    'projects."'+str(self.pane.project)+'".trust_level="trusted"']
                return [self.pane.cli,*tokens[1:],*[a for v in overrides for a in ["-c",v]],"-a","never"]
            self.pane.start(Model,args,lambda base:{})
        else:
            Model.steps={};Model.events=[];Model.completions=[];Model.pauses={};Model.began=self.began
            def args(base):
                # Exactly the generated hook-settings mode, under scratch HOME.
                config=json.loads(subprocess.check_output([str(self.bridge),"--hook-settings","--agent","opencode","--socket",str(self.root/"bridge.sock")],env=self.pane.env,text=True,timeout=10))
                config.update({"experimental":{"disable_paste_summary":True},"autoupdate":False,"share":"disabled","model":"openai/gpt-4.1-mini","enabled_providers":["openai"],
                    "provider":{"openai":{"options":{"baseURL":base+"/v1","apiKey":"sa3-local-fixture"}}},
                    "permission":"allow","mcp":{"zeus":{"type":"local","command":[str(self.bridge),"--agent","opencode","--socket",str(self.root/"bridge.sock")],"enabled":True}}})
                self.pane.env["OPENCODE_CONFIG_CONTENT"]=json.dumps(config)
                return [self.pane.cli,"--port","0","--hostname","127.0.0.1"]
            self.pane.start(Model,args,lambda base:{})
        self.pane.onboard()
        if self.agent=="claude":
            eventually(lambda:("server:zeus" in self.pane.plain() and "Yes, load this channel" in self.pane.plain()) or "❯" in self.pane.plain(),"Channel consent")
            if "Yes, load this channel" in self.pane.plain():self.pane.tm("send-keys","-t","pc1","Enter")
        if self.agent=="opencode":
            self.pane.send("SA3_BOOTSTRAP")
            eventually(lambda:"SA3_READY" in self.pane.plain(),"Native OpenCode conversation not started")
            time.sleep(.2)
        eventually(lambda:len(self.state()["sessions"])==1,"Native MCP bridge not connected",timeout=50)
        self.frame("initial-idle")
        assert self.state()["managed"]=="off","This proof must not use managed screen polling"
        time.sleep(.5)
    def run(self, interruption=False):
        self.start()
        for scenario in ["fast","second"]:
            did="d_sa3_"+scenario
            response=self.control.call("send",text="SA3_FAST",id=did);self.events.append({"name":"compose","delivery":did,"state":response["state"]})
            eventually(lambda:any(d["id"]==did and d["acked"] for d in self.state()["deliveries"]),"Native ack missing",timeout=30)
            if self.agent=="claude":
                eventually(lambda:any("SA3_SHELL_DONE" in json.dumps(b) for b in ClaudeModel.results),"Native Bash not finished")
                completed=eventually(lambda:ClaudeCompletion.finalTimes.get(did),"Native final response")
            else:
                completed=eventually(lambda:next((e["t"]+Model.began for e in Model.completions if e["delivery"]==did),None),"Native final response")
            ended=eventually(lambda:time.monotonic() if self.state()["phase"] is None else None,"Hook did not end implicit activity",timeout=4)
            self.frame(scenario+"-complete")
            value={"name":scenario,"delivery":did,"completion_t":completed-self.began,"ended_t":ended-self.began,"after_model_completion_s":ended-completed,"within_2s":ended-completed<=2}
            self.scenarios.append(value);assert value["within_2s"],value
            assert self.state()["cards"]==[],"No zeus_say/present may hide a hook failure"
            time.sleep(.8)
        if self.agent=="claude":
            ClaudeCompletion.fail=True
            self.control.call("send",text="SA3_ERROR",id="d_sa3_error")
            eventually(lambda:"SA3 synthetic stopped request" in self.pane.plain(),"Native error not rendered",timeout=15)
            ended=eventually(lambda:time.monotonic() if self.state()["phase"] is None else None,"StopFailure not consumed",timeout=3)
            self.frame("error-ended");self.scenarios.append({"name":"error","ended_t":ended-self.began,"activity_ended":True})
            ClaudeCompletion.fail=False
        if self.agent=="claude" and interruption:
            ClaudeCompletion.pauseDelivery="d_sa3_interrupt";ClaudeCompletion.pauseEntered.clear();ClaudeCompletion.pauseRelease.clear()
            self.control.call("send",text="SA3_INTERRUPT",id="d_sa3_interrupt")
            eventually(lambda:ClaudeCompletion.pauseEntered.is_set(),"Held native turn not reached")
            self.frame("before-interrupt");self.pane.tm("send-keys","-t","pc1","Escape")
            self.frame("after-interrupt")
            interrupted=time.monotonic()
            # Claude 2.1.299 excludes Escape from Stop; Notification idle_prompt
            # would be fallback evidence IF received. The recorded installed
            # CLI does not emit it within this deadline; this opt-in gate fails.
            ended=eventually(lambda:time.monotonic() if self.state()["phase"] is None else None,"Interrupted turn's idle hook not received",timeout=70)
            self.frame("interrupted-ended");self.scenarios.append({"name":"interrupt","native_idle_notification_s":ended-interrupted,"activity_ended":True})
            ClaudeCompletion.pauseRelease.set()
        return self.proof()
    def proof(self):
        self.frame("final")
        hooks=[json.loads(l) for l in (self.root/"hook-input.jsonl").read_text().splitlines()] if (self.root/"hook-input.jsonl").exists() else []
        transcripts=[json.loads(l) for p in (self.pane.home/".claude/projects").rglob("*.jsonl") for l in p.read_text().splitlines()] if self.agent=="claude" else []
        native_tools=[{"name":b["name"],"input":b.get("input")} for f in transcripts for b in f.get("message",{}).get("content",[]) if isinstance(b,dict) and b.get("type")=="tool_use"]
        transcripts=[{k:f[k] for k in ["type","promptId","timestamp","interruptedMessageId","message"] if k in f} for f in transcripts if f.get("type")=="user"]
        return {"native_tools":native_tools,"wire_hooks":[json.loads(l) for l in (self.root/"wire-hooks.jsonl").read_text().splitlines()],"hook_inputs":hooks,"transcript":transcripts,"agent":self.agent,"version":getattr(self.pane,"version",None),"launch_command":self.launch,"managed":self.state()["managed"],
            "private_socket":True,"disposable_home":True,"localhost_model":True,"scenarios":self.scenarios,"frames":self.frames,
            "events":self.events,"timeline":[json.loads(l) for l in (self.root/"timeline.jsonl").read_text().splitlines()],
            "model_calls":Model.events if self.agent!="claude" else [{"tools":[t["name"] for t in b.get("tools",[])],"results":[r for m in b.get("messages",[]) if isinstance(m.get("content"),list) for r in m["content"] if r.get("type")=="tool_result"]} for b in ClaudeModel.requests]}
    def close(self):
        ClaudeCompletion.pauseRelease.set()
        try:self.pane.close()
        finally:
            self.host.stdin.close()
            try:self.host.wait(timeout=5)
            except subprocess.TimeoutExpired:self.host.kill();self.host.wait()
            self.control.selector.close();self.log.close()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--agent",choices=["all","claude","codex","opencode"],default="all");parser.add_argument("--record",action="store_true");parser.add_argument("--interrupt-check",action="store_true");args=parser.parse_args()
    host=build_host();failed=[]
    for agent in ["claude","codex","opencode"] if args.agent=="all" else [args.agent]:
        probe=Probe(host,agent)
        try:
            try:proof=probe.run(interruption=args.interrupt_check)
            except Exception as error:proof=probe.proof();proof["error"]=str(error);failed.append(agent)
            raw=json.dumps(proof,ensure_ascii=False,indent=2);(OUT/(agent+"-proof.json")).write_text(raw)
            public=raw.replace(str(probe.root),"/FIXTURE").replace(str(probe.bridge.parent.parent.parent),"/BUNDLE/Zeus.app").replace(probe.pane.cli,"/CLI/"+agent)
            if args.record:
                target=REPO/"TestFixtures/live/sa3";target.mkdir(parents=True,exist_ok=True);(target/(agent+("-interruption" if args.interrupt_check else "")+"-probe.json")).write_text(public+"\n")
            print(json.dumps({"agent":agent,"scenarios":proof["scenarios"],"error":proof.get("error")}),flush=True)
        finally:probe.close()
    if failed:raise SystemExit("SA3 failed: "+", ".join(failed))
if __name__=="__main__":main()
