#!/usr/bin/env python3
"""Connect-your-own probe: real CLIs, localhost models, private tmux and disposable HOME."""
import argparse, http.server, json, os, pathlib, shlex, signal, socket, subprocess, threading, time, uuid
p = argparse.ArgumentParser()
for name in ('root', 'agent', 'tmux', 'cli', 'bridge', 'bridge-socket'):
    p.add_argument('--' + name, required=True)
a = p.parse_args()
root = pathlib.Path(a.root)
assert root.name.startswith('zcy1_') and root.parent.resolve() == pathlib.Path('/private/tmp')
assert not root.is_symlink() and a.agent in ('claude', 'codex', 'opencode')
home, project = root / 'home', root / 'project'
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
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def event(value, name=None):
            self.wfile.write(((('event: ' + name + '\n') if name else '') + 'data: ' + json.dumps(value) + '\n\n').encode()); self.wfile.flush()
        try:
            if a.agent == 'claude':
                msg = {'id':'msg_' + uuid.uuid4().hex, 'type':'message', 'role':'assistant', 'model':body.get('model','fixture'), 'content':[], 'stop_reason':None, 'stop_sequence':None, 'usage':{'input_tokens':1,'output_tokens':1}}
                event({'type':'message_start','message':msg}, 'message_start')
                if use_tool:
                    block = {'type':'tool_use','id':'toolu_cy1','name':say,'input':{}}
                    event({'type':'content_block_start','index':0,'content_block':block}, 'content_block_start')
                    event({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json':json.dumps(arguments)}}, 'content_block_delta')
                else:
                    event({'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}, 'content_block_start')
                    event({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'CY1_READY'}}, 'content_block_delta')
                event({'type':'content_block_stop','index':0}, 'content_block_stop')
                event({'type':'message_delta','delta':{'stop_reason':'tool_use' if use_tool else 'end_turn','stop_sequence':None},'usage':{'output_tokens':1}}, 'message_delta')
                event({'type':'message_stop'}, 'message_stop')
            elif self.path.split('?')[0].endswith('/chat/completions'):
                delta = {'tool_calls':[{'index':0,'id':'call_cy1','type':'function','function':{'name':say,'arguments':json.dumps(arguments)}}]} if use_tool else {'role':'assistant','content':'CY1_READY'}
                chunk = {'id':'chat_cy1','object':'chat.completion.chunk','created':int(time.time()),'model':body.get('model','fixture'),'choices':[{'index':0,'delta':delta,'finish_reason':None}]}
                event(chunk); chunk['choices'][0] = {'index':0,'delta':{},'finish_reason':'tool_calls' if use_tool else 'stop'}; event(chunk)
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
            else:
                if use_tool:
                    item = {'id':'fc_cy1','type':'function_call','name':say,'call_id':'call_cy1','arguments':json.dumps(arguments),'status':'completed'}
                    if namespace: item['namespace'] = namespace
                else:
                    item = {'id':'msg_' + uuid.uuid4().hex,'type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'CY1_READY','annotations':[]}]}
                response = {'id':'resp_' + uuid.uuid4().hex,'object':'response','created_at':int(time.time()),'status':'completed','model':'fixture','output':[item],'error':None,'incomplete_details':None,'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
                event({'type':'response.created','response':dict(response,status='in_progress',output=[])})
                event({'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress')})
                if not use_tool:
                    event({'type':'response.content_part.added','item_id':item['id'],'output_index':0,'content_index':0,'part':{'type':'output_text','text':'','annotations':[]}})
                    event({'type':'response.output_text.delta','item_id':item['id'],'output_index':0,'content_index':0,'delta':'CY1_READY'})
                event({'type':'response.output_item.done','output_index':0,'item':item}); event({'type':'response.completed','response':response})
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
base = 'http://127.0.0.1:' + str(server.server_port)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = {'HOME':str(home), 'CLAUDE_CONFIG_DIR':str(home/'.claude'), 'CODEX_HOME':str(home/'.codex'),
    'XDG_CONFIG_HOME':str(home/'.config'), 'XDG_DATA_HOME':str(home/'.local/share'), 'XDG_CACHE_HOME':str(home/'.cache'), 'XDG_STATE_HOME':str(home/'.local/state'),
    'TMUX_TMPDIR':str(home/'tmux'), 'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', 'LANG':'en_US.UTF-8', 'LC_ALL':'en_US.UTF-8',
    'ANTHROPIC_BASE_URL':base, 'ANTHROPIC_API_KEY':'cy1-local-fixture', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY':'1', 'DISABLE_AUTOUPDATER':'1', 'ENABLE_TOOL_SEARCH':'false',
    'OPENCODE_DISABLE_AUTOUPDATE':'true', 'OPENCODE_DISABLE_EXTERNAL_PLUGINS':'true', 'OPENCODE_DISABLE_MODELS_FETCH':'true', 'OPENCODE_DISABLE_LSP_DOWNLOAD':'true'}
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
    subprocess.run([a.tmux,'-S',tmux_socket,'kill-server'], env=env, capture_output=True, timeout=10)
    server.shutdown(); server.server_close()
