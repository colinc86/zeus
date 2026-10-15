#!/usr/bin/env python3
"""Shared live-fixture mechanics. Only explicit private namespaces, never user profiles.

Probes retain their scenario decisions/assertions; this module owns isolation,
localhost SSE transport, headless-host caching, cleanup and path scrubbing.
"""
import atexit, fcntl, hashlib, http.server, json, os, pathlib, re, selectors, shutil, signal, subprocess, sys, tempfile, threading, time, uuid
REPO=pathlib.Path(__file__).resolve().parents[4]
_ROOTS=[]
_HOST_LEASE=None
_HOST_LEASE_GUARD=threading.Lock()

def serialize_live_hosts():
    """One live fixture process per worktree, through cleanup (never a user socket).

    The descriptor is close-on-exec: agent/model children cannot keep the lease
    alive after their probe exits. The stable lock inode must not be unlinked.
    """
    global _HOST_LEASE
    with _HOST_LEASE_GUARD:
        if _HOST_LEASE is not None:return
        path=REPO/"build/live-hosts/.fixture.lock"
        path.parent.mkdir(parents=True,exist_ok=True)
        lease=path.open("a")
        try:fcntl.flock(lease,fcntl.LOCK_EX)
        except BaseException:
            lease.close()
            raise
        _HOST_LEASE=lease


def output_dir(legacy):
    value=pathlib.Path(os.environ.get("ZEUS_LIVE_OUTPUT", REPO/"build"/legacy))
    value.mkdir(parents=True,exist_ok=True)
    return value

def register_root(root):
    serialize_live_hosts()
    root=pathlib.Path(root).resolve()
    if root.parent != pathlib.Path("/private/tmp") or not root.name.startswith(("zpc1_","zsa1_","zsa2_","zsa3_","zsa4_","zac1_","zlv1_","zcy1_")):
        raise ValueError("Not an owned private live-fixture root")
    if root not in _ROOTS:
        _ROOTS.append(root)
        if registry:=os.environ.get("ZEUS_LIVE_REGISTRY"):
            with open(registry,"a") as f:f.write(json.dumps(str(root))+"\n")
    return root

def create_root(prefix):
    return register_root(tempfile.mkdtemp(prefix=prefix,dir="/tmp"))

def isolated_environment(home, extra=None):
    home=pathlib.Path(home)
    env={"HOME":str(home),"CFFIXED_USER_HOME":str(home),"PYTHONDONTWRITEBYTECODE":"1","PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "TERM":"xterm-256color","LANG":"en_US.UTF-8","LC_ALL":"en_US.UTF-8","USER":"fixture","LOGNAME":"fixture",
        "CLAUDE_CONFIG_DIR":str(home/".claude"),"CODEX_HOME":str(home/".codex"),"XDG_CONFIG_HOME":str(home/".config"),"XDG_DATA_HOME":str(home/".local/share"),"XDG_CACHE_HOME":str(home/".cache"),"XDG_STATE_HOME":str(home/".local/state"),"TMUX_TMPDIR":str(home/"tmux"),
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","CLAUDE_CODE_DISABLE_AUTO_MEMORY":"1","DISABLE_AUTOUPDATER":"1","ENABLE_TOOL_SEARCH":"false",
        "OPENCODE_DISABLE_AUTOUPDATE":"true","OPENCODE_DISABLE_EXTERNAL_PLUGINS":"true","OPENCODE_DISABLE_MODELS_FETCH":"true","OPENCODE_DISABLE_LSP_DOWNLOAD":"true"}
    for key in ["HOME","CLAUDE_CONFIG_DIR","CODEX_HOME","XDG_CONFIG_HOME","XDG_DATA_HOME","XDG_CACHE_HOME","XDG_STATE_HOME","TMUX_TMPDIR"]:
        pathlib.Path(env[key]).mkdir(parents=True,exist_ok=True)
    # Pass only gate-owned diagnostic paths, never inherited agent credentials/config.
    for key in ["ZEUS_LIVE_OUTPUT","ZEUS_LIVE_REGISTRY"]:
        if key in os.environ:env[key]=os.environ[key]
    env.update(extra or {})
    return env


def stop_host(process):
    """Close private host stdin, allow normal runtime shutdown, then bound escalation."""
    if process.stdin and not process.stdin.closed:process.stdin.close()
    try:process.wait(timeout=5)
    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)

def start_model(handler):
    server=http.server.ThreadingHTTPServer(("127.0.0.1",0),handler)
    worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
    return server,worker

def scrub_paths(value,replacements):
    """Replace raw and canonical macOS aliases, longest first; preserve fixture data."""
    aliases={}
    for source,target in replacements.items():
        aliases[str(source)]=target
        if str(source).startswith("/"):
            aliases[str(pathlib.Path(source).resolve())]=target
            if str(source).startswith("/private/tmp/"):aliases[str(source)[8:]]=target
    if isinstance(value,str):
        for source in sorted(aliases,key=len,reverse=True):value=value.replace(source,aliases[source])
    elif isinstance(value,list):value=[scrub_paths(v,replacements) for v in value]
    elif isinstance(value,dict):value={k:scrub_paths(v,replacements) for k,v in value.items()}
    return value

def cleanup_root(root,remove=True):
    """Idempotent, bounded cleanup; never infer a socket from ambient TMUX."""
    root=pathlib.Path(root)
    if not root.exists():return
    if root.is_symlink() or root.resolve().parent != pathlib.Path("/private/tmp") or not root.name.startswith(("zpc1_","zsa1_","zsa2_","zsa3_","zsa4_","zac1_","zlv1_","zcy1_")):
        raise ValueError("Refusing cleanup outside a private live fixture")
    tmux=shutil.which("tmux");socket=root/"tmux.sock"
    owned={}
    def stamp(pid):
        return subprocess.run(["/bin/ps","-p",str(pid),"-o","lstart="],capture_output=True,text=True,timeout=5).stdout.strip()
    def track(pid):
        if pid<=1 or pid in owned:return
        identity=stamp(pid)
        if not identity:return
        owned[pid]=identity
        children=subprocess.run(["/usr/bin/pgrep","-P",str(pid)],capture_output=True,text=True,timeout=5).stdout.split()
        for child in children:track(int(child))
    if tmux and socket.exists():
        panes=subprocess.run([tmux,"-S",str(socket),"list-panes","-a","-F","#{pane_pid}"],capture_output=True,text=True,timeout=10)
        if panes.returncode==0:
            for pid in panes.stdout.split():track(int(pid))
        subprocess.run([tmux,"-S",str(socket),"kill-server"],env=isolated_environment(root/"home"),capture_output=True,timeout=10)
    # Pane children can start their own process group or ignore HUP. Check the
    # captured lifetime before signaling, never a process discovered globally.
    def signal_owned(pid,signum):
        if stamp(pid)!=owned[pid]:return
        try:
            if os.getpgid(pid)==pid:os.killpg(pid,signum)
            else:os.kill(pid,signum)
        except ProcessLookupError:pass
    def live_owned():return any(stamp(pid)==identity for pid,identity in owned.items())
    # First allow the launcher to observe HUP, reap its child, and journal exit.
    deadline=time.monotonic()+3.5
    while time.monotonic()<deadline and live_owned():time.sleep(.05)
    if live_owned():
        for pid in reversed(owned):signal_owned(pid,signal.SIGTERM)
        deadline=time.monotonic()+1
        while time.monotonic()<deadline and live_owned():time.sleep(.05)
    for pid,identity in owned.items():
        if stamp(pid)==identity:signal_owned(pid,signal.SIGKILL)
    deadline=time.monotonic()+2
    while time.monotonic()<deadline and live_owned():time.sleep(.05)
    if live_owned():raise RuntimeError("Fixture-owned process lifetime survived cleanup")
    if remove:shutil.rmtree(root,ignore_errors=True)


def _cleanup_all():
    for root in reversed(_ROOTS):
        try:cleanup_root(root)
        except Exception as e:print("Live fixture cleanup:",e,file=sys.stderr)
atexit.register(_cleanup_all)

def _terminate(signum,_frame):
    raise SystemExit(128+signum)
# Give finally/atexit a chance on the gate's timeout or Ctrl-C.
signal.signal(signal.SIGTERM,_terminate)


def finish_host_build(out,package):
    """Build each native host once per source fingerprint, shared across agent rows."""
    # Runtime learning is optional; headless hosts need its Foundation-only value/protocol seams.
    # App-owned durable explicit-context intents accompany CardStore in every headless host.
    context_intent = REPO/"Zeus/Cards/ContextSendIntent.swift"
    (package/"Sources/Host/ContextSendIntent.swift").write_text(context_intent.read_text())
    seam = REPO/"Zeus/Learn/Seams.swift"
    (package/"Sources/Host/LearningSeams.swift").write_text(seam.read_text())
    if (package/"Sources/Host/PersistentRulesStore.swift").exists():
        (package/"Sources/Host/RuleLifecycle.swift").write_text((REPO/"Zeus/Learn/RuleLifecycle.swift").read_text())
    fingerprint=hashlib.sha256()
    paths=list((package/"Sources").rglob("*.swift"))+[package/"Package.swift"]
    paths+=list((REPO/"Packages/ZeusKit/Sources").rglob("*.swift"))+[REPO/"Packages/ZeusKit/Package.swift"]
    for path in sorted(paths):
        fingerprint.update(str(path).encode());fingerprint.update(path.read_bytes())
    mark=package/".live-fingerprint"
    directory=subprocess.check_output(["xcrun","swift","build","--package-path",str(package),"--show-bin-path"],text=True,timeout=30).strip()
    executable=pathlib.Path(directory)/"Host"
    if not executable.exists() or not mark.exists() or mark.read_text()!=fingerprint.hexdigest():
        with (out/"host-build.log").open("w") as log:
            subprocess.run(["xcrun","swift","build","--package-path",str(package),"--product","Host"],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=240)
        mark.write_text(fingerprint.hexdigest())
    else:(out/"host-build.log").write_text("Cached host; all source fingerprints match.\n")
    return executable

def host_package(out,name):
    serialize_live_hosts()
    package=REPO/"build/live-hosts"/name if "ZEUS_LIVE_OUTPUT" in os.environ else out/"host"
    package.mkdir(parents=True,exist_ok=True)
    # Remove copied sources so a removed production file cannot survive in the cache.
    if (package/"Sources").exists():shutil.rmtree(package/"Sources")
    return package

class Model(http.server.BaseHTTPRequestHandler):
    stage = 0
    results = []
    lock = threading.Lock()
    action = None
    requests = []
    completion_text = None

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
            Model.requests.append(body)
            background = Model.action is not None and not names
            target, arguments = (None, {}) if background else Model.action(body) if Model.action else ("zeus_app_state" if stage == 0 else "zeus_move" if stage == 1 else None, {"position": "near-active-window"} if stage == 1 else {})
            name = next((n for n in names if n == target or n.endswith("__" + target)), None) if target else None
            if target and not name:
                raise RuntimeError(f"Expected {target} in real Claude model tools: {names}")
            if not background:
                Model.stage += 1
                Model.results = [block for message in body.get("messages", []) if isinstance(message.get("content"), list)
                    for block in message["content"] if block.get("type") == "tool_result"]
        stream_reply(self,"anthropic",body,name,arguments,
            Model.completion_text if Model.completion_text is not None else "AC1_PROVED" if Model.action is None else "LV1_PROVED")

class HostControl:
    """Serial test-only stdin commands; a response is required, never inferred from sleep."""
    def __init__(self, process):
        self.process = process
        self.lock = threading.Lock()
        self.selector = selectors.DefaultSelector()
        self.selector.register(process.stdout, selectors.EVENT_READ)

    def read(self):
        if not self.selector.select(timeout=15):
            raise TimeoutError("LV1 host response stalled")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("LV1 host exited")
        value = json.loads(line)
        assert value.get("ok", value.get("ready", False)), value
        return value

    def call(self, command, **fields):
        with self.lock:
            self.process.stdin.write(json.dumps(dict(command=command, **fields)) + "\n")
            self.process.stdin.flush()
            return self.read()

def eventually(check, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise TimeoutError(description)

class Pane:
    def __init__(self,agent,native_updater=False, prefix="zpc1_", output=None):
        self.agent=agent;self.root=create_root(prefix);self.output=output or output_dir("pc1-live")
        self.home=self.root/'home';self.project=self.root/'project';self.home.mkdir();self.project.mkdir()
        for d in ['.claude','.codex','.config','.cache','.local/share','.local/state','tmux']:(self.home/d).mkdir(parents=True)
        self.socket=str(self.root/'tmux.sock');self.tmux=shutil.which('tmux');self.cli=shutil.which(agent)
        assert self.tmux and self.cli
        self.env=isolated_environment(self.home)
        self.native_updater=native_updater
        if native_updater:
            version=subprocess.check_output([self.cli,'--version'],env=self.env,text=True,timeout=10).split()[0]
            binary=self.home/'.local/share/claude/versions'/version;binary.parent.mkdir(parents=True)
            shutil.copy2(pathlib.Path(self.cli).resolve(),binary)
            launch=self.home/'.local/bin/claude';launch.parent.mkdir(parents=True);launch.symlink_to(binary)
            assert launch.resolve().is_relative_to(self.home)
            self.cli=str(launch)
        self.server=None;self.worker=None;self.captures=[]
        if native_updater:
            self.env.pop('DISABLE_AUTOUPDATER');self.env.pop('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')
    def tm(self,*args,input=None):
        return subprocess.run([self.tmux,'-u','-S',self.socket,'-f','/dev/null',*args],env=self.env,input=input,capture_output=True,text=True,check=True,timeout=10).stdout
    def snapshot(self):
        return {'screen':self.tm('capture-pane','-p','-e','-t','pc1'), 'inputMetadata':self.tm('display-message','-p','-t','pc1','#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}|#{bracket_paste_flag}').strip()}
    def plain(self):return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',self.snapshot()['screen'])
    def capture(self,name,provenance):
        raw=self.snapshot();(self.output/(name+'.raw.json')).write_text(json.dumps(raw,indent=2))
        public=dict(raw,agent=self.agent,version=self.version,provenance=provenance)
        public['screen']=scrub_paths(public['screen'], {str(self.root):'/FIXTURE'})
        self.captures.append((name,public));return public
    def start(self,handler,argv,env):
        self.server,self.worker=start_model(handler)
        base=f'http://127.0.0.1:{self.server.server_port}'
        self.env.update(env(base));args=argv(base)
        self.version=subprocess.check_output([self.cli,'--version'],env=self.env,text=True,timeout=10).strip()
        profile={'hasCompletedOnboarding':True,'theme':'dark','hasAcknowledgedCostThreshold':True,'projects':{str(self.project):{'hasTrustDialogAccepted':True}}}
        if self.native_updater:profile.update(installMethod='native',autoUpdates=True)
        for p in [self.home/'.claude.json',self.home/'.claude/.claude.json']:p.write_text(json.dumps(profile))
        launch=self.root/'launch.py'
        launch.write_text('import os,json,signal,subprocess,pathlib,threading\n'+f'argv=json.loads({json.dumps(json.dumps(args))})\nenv=json.loads({json.dumps(json.dumps(self.env))})\n'+
            "env.update({k:os.environ[k] for k in ['TMUX','TMUX_PANE'] if k in os.environ})\nchild=None\ndef stop(*_):\n if child is not None and child.poll() is None:\n  os.killpg(child.pid,signal.SIGTERM)\n  def force():\n   if child.poll() is None:os.killpg(child.pid,signal.SIGKILL)\n  t=threading.Timer(3,force);t.daemon=True;t.start()\nsignal.signal(signal.SIGHUP,stop);signal.signal(signal.SIGTERM,stop)\nchild=subprocess.Popen(argv,env=env,start_new_session=True)\n"+
            f"pathlib.Path({str(self.root/'agent.pid')!r}).write_text(str(child.pid))\nstatus=child.wait()\npathlib.Path({str(self.root/'exit')!r}).write_text(str(status))\n")
        self.tm('new-session','-d','-s','pc1','-x','120','-y','40','-c',str(self.project),'/bin/sleep','600');self.tm('set-option','-w','-t','pc1','remain-on-exit','on')
        self.tm('respawn-pane','-k','-t','pc1:0.0','-c',str(self.project),sys.executable,str(launch))
    def onboard(self):
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            s=self.plain()
            if 'Quick safety check:' in s and str(self.project) in s and 'Yes, I trust this folder' in s:self.tm('send-keys','-t','pc1','Down','Enter')
            elif 'Do you want to use this API key?' in s:self.tm('send-keys','-t','pc1','Up','Enter')
            elif '❯' in s or ('Ask Codex to do anything' in s) or ('ctrl+p commands' in s):return
            time.sleep(.2)
        raise TimeoutError('Private '+self.agent+' onboarding: '+self.plain())
    def send(self,text,submit=True):
        self.tm('load-buffer','-b','pc1-input','-',input=text);self.tm('paste-buffer','-p','-d','-b','pc1-input','-t','pc1')
        time.sleep(.15)
        if submit:self.tm('send-keys','-t','pc1','Enter')
    def close(self):
        if (self.root/'tmux.sock').exists():
            try:(self.output/(self.agent+'-final.json')).write_text(json.dumps(self.snapshot(),indent=2))
            except subprocess.SubprocessError:pass
        cleanup_root(self.root, remove=False)
        # cleanup_root checks actual pane/agent lifetimes even if a force-killed
        # launcher cannot write its optional exit journal.
        if self.server:self.server.shutdown();self.server.server_close();self.worker.join(timeout=2)
        cleanup_root(self.root)



def stream_reply(handler, protocol, body, tool, args, text, namespace=None, pause=None):
    """Local model SSE transport shared by all scripted probe policies."""
    handler.send_response(200);handler.send_header("Content-Type","text/event-stream");handler.end_headers()
    def event(value):
        name="event: "+value["type"]+"\n" if protocol=="anthropic" else ""
        handler.wfile.write((name+"data: "+json.dumps(value)+"\n\n").encode());handler.wfile.flush()
    try:
        if protocol=="anthropic":
            event({"type":"message_start","message":{"id":"msg_"+uuid.uuid4().hex,"type":"message","role":"assistant","model":body.get("model"),"content":[],"stop_reason":None,"stop_sequence":None,"usage":{"input_tokens":1,"output_tokens":1}}})
            content={"type":"tool_use","id":"tool_"+uuid.uuid4().hex,"name":tool,"input":{}} if tool else {"type":"text","text":""}
            event({"type":"content_block_start","index":0,"content_block":content})
            delta={"type":"input_json_delta","partial_json":json.dumps(args)} if tool else {"type":"text_delta","text":text}
            event({"type":"content_block_delta","index":0,"delta":delta});event({"type":"content_block_stop","index":0})
            event({"type":"message_delta","delta":{"stop_reason":"tool_use" if tool else "end_turn","stop_sequence":None},"usage":{"output_tokens":1}});event({"type":"message_stop"})
        elif protocol=="chat":
            chunk={"id":"chat_fixture","object":"chat.completion.chunk","created":int(time.time()),"model":body.get("model","fixture"),"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":None}]}
            event(chunk)
            if pause:pause.wait(timeout=45)
            delta={"tool_calls":[{"index":0,"id":"call_"+uuid.uuid4().hex,"type":"function","function":{"name":tool,"arguments":json.dumps(args)}}]} if tool else {"content":text}
            chunk["choices"][0]={"index":0,"delta":delta,"finish_reason":None};event(chunk)
            chunk["choices"][0]={"index":0,"delta":{},"finish_reason":"tool_calls" if tool else "stop"};event(chunk)
            handler.wfile.write(b"data: [DONE]\n\n");handler.wfile.flush()
        elif protocol=="responses":
            item={"id":"fc_"+uuid.uuid4().hex,"type":"function_call","name":tool,"call_id":"call_"+uuid.uuid4().hex,"arguments":json.dumps(args),"status":"completed"} if tool else {"id":"msg_"+uuid.uuid4().hex,"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text,"annotations":[]}]}
            if namespace:item["namespace"]=namespace
            response={"id":"resp_"+uuid.uuid4().hex,"object":"response","created_at":int(time.time()),"status":"completed","model":"fixture","output":[item],"error":None,"incomplete_details":None,"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}
            event({"type":"response.created","response":dict(response,status="in_progress",output=[])})
            event({"type":"response.output_item.added","output_index":0,"item":dict(item,status="in_progress")})
            if pause:pause.wait(timeout=45)
            if not tool:
                event({"type":"response.content_part.added","item_id":item["id"],"output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}})
                event({"type":"response.output_text.delta","item_id":item["id"],"output_index":0,"content_index":0,"delta":text})
            event({"type":"response.output_item.done","output_index":0,"item":item});event({"type":"response.completed","response":response})
        else:raise ValueError("Unknown local SSE protocol")
    except (BrokenPipeError,ConnectionResetError):pass


class OpenAIModel(http.server.BaseHTTPRequestHandler):
    tag = "SA3"
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
        cls = type(self)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        chat = self.path.split("?")[0].endswith("/chat/completions")
        messages = body.get("messages" if chat else "input", [])
        users = [m.get("content", "") for m in messages if isinstance(m, dict) and m.get("role") == "user"]
        history = json.dumps(users)
        triggers = re.findall(re.escape(cls.tag) + r"_(?:SAY|SHELL|FAST|BUSY|FOLLOWUP|DRAFT)", history)
        scenario = triggers[-1] if triggers else "bootstrap"
        ids = re.findall(r"delivery_id=(d_" + cls.tag.lower() + r"_[a-z]+)", history)
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
        with cls.lock:
            step = cls.steps.get(delivery, 0)
            tool, args = None, {}
            if delivery and step == 0:
                tool, args = name("zeus_ack"), {"delivery_ids": [delivery]}
            elif delivery and step == 1 and scenario in [cls.tag+"_SAY", cls.tag+"_FOLLOWUP"]:
                tool, args = name("zeus_say"), {"text": scenario + " native bridge reply."}
            elif delivery and step == 1:
                tool = name("exec_command" if "exec_command" in names else "bash")
                args = {"cmd": "printf " + cls.tag + "_SHELL_DONE"} if tool == "exec_command" else {"command": "printf " + cls.tag + "_SHELL_DONE", "description": "Print the isolated state fixture marker"}
            cls.steps[delivery] = step + 1
            cls.events.append({"t": time.monotonic() - cls.began, "scenario": scenario, "delivery": delivery, "step": step, "tool": tool,
                "tool_results": [m for m in messages if isinstance(m, dict) and (m.get("type") == "function_call_output" or m.get("role") == "tool")]})
        pause = cls.pauses.get(scenario) if delivery and step >= 2 and not tool else None
        text = cls.tag + "_READY" if not delivery else scenario + " native turn complete."
        stream_reply(self, "chat" if chat else "responses", body, tool, args, text,
                     next((ns for n, ns in tools if n == tool),None), pause)
        if delivery and not tool:
            cls.completions.append({"delivery":delivery,"t":time.monotonic()-cls.began})
