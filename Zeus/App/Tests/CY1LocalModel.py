#!/usr/bin/env python3
"""Connect-your-own probe: real CLIs, localhost models, private tmux and disposable HOME."""
import argparse, http.server, json, os, pathlib, shlex, signal, socket, subprocess, threading, time, uuid
import sys
sys.dont_write_bytecode = True
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent/"Runtime"))
from LiveSupport import register_root, isolated_environment, start_model, stream_reply, cleanup_root
p = argparse.ArgumentParser()
for name in ('root', 'agent', 'tmux', 'cli', 'bridge', 'bridge-socket'):
    p.add_argument('--' + name, required=True)
a = p.parse_args()
root = register_root(a.root)
assert root.name.startswith('zcy1_') and root.parent.resolve() == pathlib.Path('/private/tmp')
assert not root.is_symlink() and a.agent in ('claude', 'codex', 'opencode')
home, project = root / 'home', root / 'home' / 'project'
for d in (home, project): d.mkdir(exist_ok=True)
for d in ('.claude', '.codex', '.config/opencode', '.cache', '.local/share', '.local/state', 'tmux'):
    (home / d).mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
emitted = False
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        with lock:
            with (root / 'requests.ndjson').open('a') as f: f.write(json.dumps(body) + '\n')
        if self.path.split('?')[0].endswith('/count_tokens'):
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(b'{"input_tokens":1}'); return
        global emitted
        tools = []
        for tool in body.get('tools', []):
            if tool.get('type') == 'namespace':
                tools += [(nested.get('name', ''), tool['name']) for nested in tool.get('tools', [])]
            else: tools.append((tool.get('function', tool).get('name', ''), None))
        say, namespace = next(((name, ns) for name, ns in tools if name.endswith('zeus_say')), (None, None))
        with lock:
            use_tool = say and not emitted and 'CY1_COMPOSE_PROBE' in json.dumps(body)
            if use_tool: emitted = True
        text = 'CY1 ' + a.agent + ' received the composer message through Connect your own.'
        arguments = {'text': text}
        stream_reply(self, 'anthropic' if a.agent=='claude' else 'chat' if self.path.split('?')[0].endswith('/chat/completions') else 'responses', body, say if use_tool else None, arguments, 'CY1_READY', namespace)

server,worker = start_model(Model)
base = 'http://127.0.0.1:' + str(server.server_port)

env = isolated_environment(home, {'ANTHROPIC_BASE_URL':base, 'ANTHROPIC_API_KEY':'cy1-local-fixture'})
profile = {'hasCompletedOnboarding':True,'theme':'dark','hasAcknowledgedCostThreshold':True}
for path in (home/'.claude.json', home/'.claude/.claude.json'): path.write_text(json.dumps(profile))
(home/'.codex/config.toml').write_text('check_for_update_on_startup=false\nmodel="cy1"\nmodel_provider="cy1"\n[model_providers.cy1]\nname="CY1 localhost fixture"\nbase_url="'+base+'/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[projects.'+json.dumps(str(project))+']\ntrust_level="trusted"\n')
bridge_args = [a.bridge, '--agent', a.agent, '--socket', a.bridge_socket]
http_url = None
if a.agent in ('claude','codex'):
    # The Settings commands write only this disposable profile, never the user's config.
    registration = [a.cli, 'mcp', 'add'] + (['-s','user'] if a.agent == 'claude' else []) + ['zeus','--'] + bridge_args
    subprocess.run(registration, env=env, cwd=project, check=True, capture_output=True, timeout=20)
    (root/'registration.json').write_text(json.dumps(registration))
    if a.agent == 'claude':
        argv = [a.cli, '--dangerously-load-development-channels', 'server:zeus', '--allowedTools', 'mcp__zeus__zeus_say', '--permission-mode', 'manual', 'CY1_READY']
    else:
        with (home/'.codex/config.toml').open('a') as f: f.write('\n[mcp_servers.zeus.tools]\nzeus_say={approval_mode="approve"}\n')
        argv = [a.cli, '--no-daemon', '-c', 'mcp_servers.zeus.env_vars=["TMUX","TMUX_PANE"]', 'CY1_READY']
else:
    port_socket = socket.socket(); port_socket.bind(('127.0.0.1',0)); port = port_socket.getsockname()[1]; port_socket.close()
    config = {'autoupdate':False,'share':'disabled','model':'openai/gpt-4.1-mini','enabled_providers':['openai'], 'provider':{'openai':{'options':{'baseURL':base+'/v1','apiKey':'cy1-local-fixture'}}},
        'mcp':{'zeus':{'type':'local','command':bridge_args,'enabled':True}},'permission':{'*':'ask','zeus_*':'allow'},'experimental':{'disable_paste_summary':True}}
    (home/'.config/opencode/opencode.json').write_text(json.dumps(config))
    argv = [a.cli, '--port', str(port), '--hostname','127.0.0.1','--prompt','CY1_READY']
    http_url = 'http://127.0.0.1:' + str(port)
tmux_socket = str(root/'tmux.sock')
command = ['/usr/bin/env'] + [key+'='+value for key,value in env.items()] + argv
subprocess.run([a.tmux, '-u','-S',tmux_socket,'new-session','-d','-x','120','-y','40','-s','own-'+a.agent,'-c',str(project),shlex.join(command)], env=env, check=True, capture_output=True, timeout=10)
(root/'launch.json').write_text(json.dumps(command))
(root/'ready.json').write_text(json.dumps({'baseURL':base,'openCodeURL':http_url}))
stop = threading.Event()
for sig in (signal.SIGTERM, signal.SIGINT): signal.signal(sig, lambda *_:stop.set())
try: stop.wait()
finally:
    cleanup_root(root,remove=False)
    server.shutdown(); server.server_close()
