#!/usr/bin/env python3
"""SA4 real Connect-your-own native completion; private tmux/HOME and localhost model.

Run after build.sh. --record copies scrubbed successful/failing facts and ANSI
frames, never private profiles, to TestFixtures/live/sa4. No default tmux access.
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

from LiveSupport import OpenAIModel, output_dir, create_root, isolated_environment, start_model, finish_host_build, host_package, scrub_paths, cleanup_root

REPO = pathlib.Path(__file__).resolve().parents[4]
OUT = output_dir("sa4-live")
OUT.mkdir(parents=True, exist_ok=True)


def build_host():
    package = host_package(OUT, "sa4")
    source = package / "Sources/Host"
    source.mkdir(parents=True, exist_ok=True)
    inputs = [REPO / p for p in ["Zeus/App/Tests/Runtime/SA4RuntimeHost.swift", "Zeus/Shared/AppSeams.swift", "Zeus/Settings/AppSettings.swift", "Zeus/Settings/AssistantBackend.swift", "Zeus/Settings/SessionLabels.swift", "Zeus/Settings/OpenCodePasswordStore.swift", "Zeus/Settings/OpenCodeSessionDiscovery.swift", "Zeus/Settings/TmuxPaneDiscovery.swift", "Zeus/Settings/LibraryImport.swift", "Zeus/Settings/SettingsStyle.swift", "Zeus/App/KeyboardButton.swift", "Zeus/Settings/TalkHotKey.swift", "Zeus/Cards/ConversationWidth.swift", "Zeus/Avatar/AvatarGhostState.swift", "Zeus/App/PopupSound.swift", "Zeus/Cards/PeekModel.swift",
        "Zeus/Cards/CardStore.swift", "Zeus/Cards/ThreadNotice.swift", "Zeus/Cards/AttachmentTarget.swift",
        "Zeus/Avatar/AvatarStatusModel.swift", "Zeus/Cards/ConversationActivityRow.swift"]]
    inputs += [p for area in ["Zeus/Bridge", "Zeus/Agents"] for p in (REPO / area).glob("*.swift") if p.name != "DebugSpriteFrameCounter.swift"]
    for path in inputs:
        value=path.read_text()
        (source/path.name).write_text(value)
    products = ",".join(f'.product(name: "{name}", package: "ZeusKit")' for name in ["ZeusProtocol", "ZeusLink", "ZeusSprites", "ZeusDesign"])
    (package / "Package.swift").write_text('// swift-tools-version: 6.2\nimport PackageDescription\n' +
        f'let package = Package(name: "SA4Host", platforms: [.macOS(.v26)], dependencies: [.package(path: {json.dumps(str(REPO / "Packages/ZeusKit"))})], targets: [.executableTarget(name: "Host", dependencies: [{products}], swiftSettings: [.define("SA4_PROBE_HOST")])])\n')
    return finish_host_build(OUT, package)


class Model(OpenAIModel):
    tag="SA4"



from LiveSupport import Pane
from LiveSupport import Model as ClaudeModel, HostControl, eventually

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
            self.wfile.write(b'{"type":"error","error":{"type":"invalid_request_error","message":"SA4 synthetic stopped request"}}')
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
        self.pane=Pane(agent, prefix="zsa4_", output=OUT)
        root=self.pane.root
        self.root=root; self.frames={}; self.events=[]; self.scenarios=[]; self.began=time.monotonic()
        self.bridge=REPO/"build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp"
        self.log=(OUT/(agent+"-host.log")).open("w")
        self.host=subprocess.Popen([str(host),str(root),str(self.bridge),agent,self.pane.tmux],env=self.pane.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True)
        self.control=HostControl(self.host); self.ready=self.control.read(); self.launch="user-style launch without hooks"
    def state(self):return self.control.call("state")["state"]
    def frame(self,name):
        frame=self.pane.snapshot();self.frames[name]=frame;return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]","",frame["screen"])
    def native_args(self,builder):
        def checked(base):
            value=builder(base);self.argv=value
            assert not any(a in value for a in ["--settings","--plugin-dir","--channels","--dangerously-load-development-channels"])
            assert not any(a.startswith("notify=") for a in value)
            assert "plugin" not in json.loads(self.pane.env.get("OPENCODE_CONFIG_CONTENT","{}"))
            return value
        return checked
    def native_idle(self):
        frame=self.pane.snapshot()
        if self.control.call("classify",screen=frame["screen"],metadata=frame["inputMetadata"])["classification"]=="idle":return frame
        return None
    def start(self):
        if self.agent=="claude":
            ClaudeModel.stage=0;ClaudeModel.requests=[];ClaudeModel.results=[];ClaudeModel.completion_text="SA4 native turn complete.";ClaudeCompletion.completed=[];ClaudeCompletion.fail=False;ClaudeCompletion.finalTimes={}
            def action(body):
                users=[m.get("content",[]) for m in body.get("messages",[]) if m.get("role")=="user"]
                raw=json.dumps(users); ids=re.findall(r"delivery_id=(d_sa4_[a-z]+)",raw);did=ids[-1] if ids else None
                results=[b for m in body.get("messages",[]) if isinstance(m.get("content"),list) for b in m["content"] if b.get("type")=="tool_result"]
                if did and not any(did in json.dumps(b) for b in results):return "zeus_ack",{"delivery_ids":[did]}
                if did and not any("SA4_SHELL_DONE" in json.dumps(b) for b in results):return "Bash",{"command":"printf SA4_SHELL_DONE","description":"Print private fixture marker"}
                ClaudeCompletion.local.delivery=did
                if did and did==ClaudeCompletion.pauseDelivery:
                    ClaudeCompletion.pauseEntered.set();ClaudeCompletion.pauseRelease.wait(timeout=90)
                return None,{}
            ClaudeModel.action=action
            def args(base):
                config=self.root/"mcp.json"
                # Step 1, same server definition, scoped only to this scratch launch.
                config.write_text(json.dumps({"mcpServers":{"zeus":{"command":str(self.bridge),"args":["--agent","claude","--socket",str(self.root/"bridge.sock")]}}}))
                return [self.pane.cli,"--mcp-config",str(config),"--model","claude-haiku-4-5","--permission-mode","manual","--allowedTools","mcp__zeus__zeus_ack,Bash"]
            self.pane.start(ClaudeCompletion,self.native_args(args),lambda base:{"ANTHROPIC_API_KEY":"sa4-local-fixture","ANTHROPIC_BASE_URL":base})
        elif self.agent=="codex":
            Model.steps={};Model.events=[];Model.completions=[];Model.pauses={};Model.began=self.began
            def args(base):
                subprocess.run([self.pane.cli,"mcp","add","zeus","--",str(self.bridge),"--agent","codex","--socket",str(self.root/"bridge.sock")],env=self.pane.env,cwd=self.pane.project,check=True,capture_output=True,timeout=15)
                # A user-style Codex launch in the fixture's existing PRIVATE
                # pane: preserve namespace env_vars; no completion notify.
                tokens=["codex","--no-daemon","-c",'mcp_servers.zeus.env_vars=["TMUX","TMUX_PANE"]']
                assert tokens[0]=="codex",tokens
                overrides=['mcp_servers.zeus.tools.zeus_ack.approval_mode="approve"',"check_for_update_on_startup=false",'model="sa4"','model_provider="sa4"',
                    'model_providers.sa4={name="SA4 localhost",base_url="'+base+'/v1",wire_api="responses",requires_openai_auth=false}',
                    'projects."'+str(self.pane.project)+'".trust_level="trusted"']
                return [self.pane.cli,*tokens[1:],*[a for v in overrides for a in ["-c",v]],"-a","never"]
            self.pane.start(Model,self.native_args(args),lambda base:{})
        else:
            Model.steps={};Model.events=[];Model.completions=[];Model.pauses={};Model.began=self.began
            def args(base):
                config={} # No plugin, hook, or notify config.
                config.update({"experimental":{"disable_paste_summary":True},"autoupdate":False,"share":"disabled","model":"openai/gpt-4.1-mini","enabled_providers":["openai"],
                    "provider":{"openai":{"options":{"baseURL":base+"/v1","apiKey":"sa4-local-fixture"}}},
                    "permission":"allow","mcp":{"zeus":{"type":"local","command":[str(self.bridge),"--agent","opencode","--socket",str(self.root/"bridge.sock")],"enabled":True}}})
                self.pane.env["OPENCODE_CONFIG_CONTENT"]=json.dumps(config)
                return [self.pane.cli,"--port","0","--hostname","127.0.0.1"]
            self.pane.start(Model,self.native_args(args),lambda base:{})
        self.pane.onboard()
        if self.agent=="opencode":
            self.pane.send("SA4_BOOTSTRAP")
            eventually(lambda:"SA4_READY" in self.pane.plain(),"Native OpenCode conversation not started")
            time.sleep(.2)
        eventually(lambda:len(self.state()["sessions"])==1,"Native MCP bridge not connected",timeout=50)
        selected=self.control.call("select");assert selected["selected"],selected
        self.frame("initial-idle")
        assert self.state()["screen_reads"]==0
        assert self.state()["managed"]=="off","This proof must not use managed screen polling"
        time.sleep(.5)
    def run(self, quick=False):
        self.start()
        for scenario in (["fast"] if quick else ["fast","second"]):
            did="d_sa4_"+scenario
            response=self.control.call("send",text="SA4_FAST",id=did);self.events.append({"name":"compose","delivery":did,"state":response["state"]})
            eventually(lambda:any(d["id"]==did and d["acked"] for d in self.state()["deliveries"]),"Native ack missing",timeout=30)
            if self.agent=="claude":
                eventually(lambda:any("SA4_SHELL_DONE" in json.dumps(b) for b in ClaudeModel.results),"Native Bash not finished")
                completed=eventually(lambda:ClaudeCompletion.finalTimes.get(did),"Native final response")
            else:
                completed=eventually(lambda:next((e["t"]+Model.began for e in Model.completions if e["delivery"]==did),None),"Native final response")
            self.frames[scenario+"-native-idle"]=eventually(self.native_idle,"Native prompt did not return")
            prompt_returned=time.monotonic()
            ended=eventually(lambda:time.monotonic() if self.state()["phase"] is None else None,"Selected own screen did not end implicit activity",timeout=5)
            self.frame(scenario+"-complete")
            value={"name":scenario,"delivery":did,"native_prompt_t":prompt_returned-self.began,"after_prompt_s":ended-prompt_returned,"completion_t":completed-self.began,"ended_t":ended-self.began,"after_model_completion_s":ended-completed,"within_5s":ended-completed<=5}
            self.scenarios.append(value);assert value["within_5s"],value
            assert self.state()["cards"]==[],"No zeus_say/present may hide a screen failure"
            time.sleep(.8)
        reads=self.state()["screen_reads"];time.sleep(3.3)
        assert self.state()["screen_reads"]==reads and not self.state()["sampling"],"Idle runtime must not keep capturing"
        return self.proof()
    def proof(self):
        self.frame("final")
        transcripts=[json.loads(l) for p in (self.pane.home/".claude/projects").rglob("*.jsonl") for l in p.read_text().splitlines()] if self.agent=="claude" else []
        native_tools=[{"name":b["name"],"input":b.get("input")} for f in transcripts for b in f.get("message",{}).get("content",[]) if isinstance(b,dict) and b.get("type")=="tool_use"]
        transcripts=[{k:f[k] for k in ["type","promptId","timestamp","interruptedMessageId","message"] if k in f} for f in transcripts if f.get("type")=="user"]
        return {"idle_captures_stopped":not self.state()["sampling"],"launch_argv":getattr(self,"argv",[]),"hooks_absent":True,"settings_selection":self.state()["selected_pane"],"screen_reads":self.state()["screen_reads"],"native_tools":native_tools,"transcript":transcripts,"agent":self.agent,"version":getattr(self.pane,"version",None),"launch_command":self.launch,"managed":self.state()["managed"],
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
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--quick",action="store_true");parser.add_argument("--agent",choices=["all","claude","codex","opencode"],default="all");parser.add_argument("--record",action="store_true");args=parser.parse_args()
    host=build_host();failed=[]
    for agent in ["claude","codex","opencode"] if args.agent=="all" else [args.agent]:
        probe=Probe(host,agent)
        try:
            try:proof=probe.run(quick=args.quick)
            except Exception as error:proof=probe.proof();proof["error"]=str(error);failed.append(agent)
            raw=json.dumps(proof,ensure_ascii=False,indent=2);(OUT/(agent+"-proof.json")).write_text(raw)
            public=scrub_paths(raw, {str(probe.root):"/FIXTURE", str(probe.bridge.parent.parent.parent):"/BUNDLE/Zeus.app", probe.pane.cli:"/CLI/"+agent})
            if args.record:
                target=REPO/"TestFixtures/live/sa4";target.mkdir(parents=True,exist_ok=True);(target/(agent+"-probe.json")).write_text(public+"\n")
            print(json.dumps({"agent":agent,"scenarios":proof["scenarios"],"error":proof.get("error")}),flush=True)
        finally:probe.close()
    if failed:raise SystemExit("SA4 failed: "+", ".join(failed))
if __name__=="__main__":main()
