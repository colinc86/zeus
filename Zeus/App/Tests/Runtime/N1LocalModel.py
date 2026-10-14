#!/usr/bin/env python3
"""N1 real-TUI fixture: localhost model only, private socket, synthetic keys and disposable profiles."""
import argparse, http.server, json, os, pathlib, signal, subprocess, threading, time, uuid
p=argparse.ArgumentParser(); p.add_argument('--root',required=True); p.add_argument('--agent',required=True); p.add_argument('--tmux',required=True); p.add_argument('--cli',required=True); p.add_argument('--paste-summary', action='store_true')
a=p.parse_args(); root=pathlib.Path(a.root)
assert root.name.startswith('zn1_') and root.parent.resolve()==pathlib.Path('/private/tmp').resolve()
assert not root.is_symlink() and a.agent in ('claude', 'codex', 'opencode')
home=root/'home'; project=root/'project'; home.mkdir(parents=True,exist_ok=True); project.mkdir(exist_ok=True)
for d in ['.claude','.codex','.config','.cache','.local/share','.local/state','tmux']: (home/d).mkdir(parents=True,exist_ok=True)
socket=str(root/'tmux.sock'); lock=threading.Lock()
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
        with lock:
            with (root/'requests.ndjson').open('a') as f: f.write(json.dumps(body)+'\n')
        if self.path.split('?')[0].endswith('/count_tokens'):
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"input_tokens":1}'); return
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        def event(v,name=None):
            self.wfile.write(((('event: '+name+'\n') if name else '')+'data: '+json.dumps(v)+'\n\n').encode()); self.wfile.flush()
        try:
            if a.agent=='claude':
                msg={'id':'msg_'+uuid.uuid4().hex,'type':'message','role':'assistant','model':body.get('model','fixture'),'content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}}
                event({'type':'message_start','message':msg},'message_start')
                event({'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}},'content_block_start')
                event({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Ready.'}},'content_block_delta')
                event({'type':'content_block_stop','index':0},'content_block_stop')
                event({'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':1}},'message_delta')
                event({'type':'message_stop'},'message_stop')
            elif self.path.split('?')[0].endswith('/chat/completions'):
                chunk={'id':'chat_n1','object':'chat.completion.chunk','created':int(time.time()),'model':body.get('model','n1'),'choices':[{'index':0,'delta':{'role':'assistant','content':'Ready.'},'finish_reason':None}]}
                event(chunk); chunk['choices'][0]={'index':0,'delta':{},'finish_reason':'stop'}; event(chunk); self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
            else:
                item={'id':'msg_'+uuid.uuid4().hex,'type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Ready.','annotations':[]}]}
                response={'id':'resp_'+uuid.uuid4().hex,'object':'response','created_at':int(time.time()),'status':'completed','model':'n1','output':[item],'error':None,'incomplete_details':None,'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
                event({'type':'response.created','response':dict(response,status='in_progress',output=[])})
                event({'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress')})
                event({'type':'response.content_part.added','item_id':item['id'],'output_index':0,'content_index':0,'part':{'type':'output_text','text':'','annotations':[]}})
                event({'type':'response.output_text.delta','item_id':item['id'],'output_index':0,'content_index':0,'delta':'Ready.'})
                event({'type':'response.output_item.done','output_index':0,'item':item}); event({'type':'response.completed','response':response})
        except (BrokenPipeError,ConnectionResetError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Model); threading.Thread(target=server.serve_forever,daemon=True).start()
base='http://127.0.0.1:'+str(server.server_port)
env={'HOME':str(home),'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin','TERM':'xterm-256color','USER':'fixture','LOGNAME':'fixture','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8',
 'CLAUDE_CONFIG_DIR':str(home/'.claude'),'CODEX_HOME':str(home/'.codex'),'XDG_CONFIG_HOME':str(home/'.config'),'XDG_DATA_HOME':str(home/'.local/share'),'XDG_CACHE_HOME':str(home/'.cache'),'XDG_STATE_HOME':str(home/'.local/state'),'TMUX_TMPDIR':str(home/'tmux'),
 'ANTHROPIC_BASE_URL':base,'ANTHROPIC_API_KEY':'n1-local-fixture','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','CLAUDE_CODE_DISABLE_AUTO_MEMORY':'1','DISABLE_AUTOUPDATER':'1','ENABLE_TOOL_SEARCH':'false',
 'OPENCODE_DISABLE_AUTOUPDATE':'true','OPENCODE_DISABLE_EXTERNAL_PLUGINS':'true','OPENCODE_DISABLE_MODELS_FETCH':'true','OPENCODE_DISABLE_LSP_DOWNLOAD':'true'}
def run(*args):
    return subprocess.run([a.tmux,'-u','-f','/dev/null','-S',socket,*args],env=env,capture_output=True,check=True,timeout=8).stdout.decode()
profile={'hasCompletedOnboarding':True,'theme':'dark','hasAcknowledgedCostThreshold':True}
for path in [home/'.claude.json',home/'.claude/.claude.json']: path.write_text(json.dumps(profile))
if a.agent=='claude': argv=[a.cli]
elif a.agent=='codex':
    opts=['check_for_update_on_startup=false','model="n1"','model_provider="n1"',f'model_providers.n1={{name="N1 localhost fixture",base_url="{base}/v1",wire_api="responses",requires_openai_auth=false}}',f'projects.{json.dumps(str(project))}.trust_level="trusted"']
    argv=[a.cli,'--no-daemon',*[v for o in opts for v in ['-c',o]]]
else:
    env['OPENCODE_CONFIG_CONTENT']=json.dumps({'autoupdate':False,'share':'disabled','model':'openai/gpt-4.1-mini','enabled_providers':['openai'],'provider':{'openai':{'options':{'baseURL':base+'/v1','apiKey':'n1-local-fixture'}}},'experimental':{'disable_paste_summary':not a.paste_summary}})
    argv=[a.cli,str(project),'--prompt','N1 fixture startup']
stop=threading.Event()
def finish(*args): stop.set()
signal.signal(signal.SIGTERM,finish); signal.signal(signal.SIGINT,finish)
try:
    run('new-session','-d','-s','n1','-x','120','-y','40','-c',str(project),'/usr/bin/env','-i',*[f'{k}={v}' for k,v in env.items()],*argv)
    (root/'ready.json').write_text(json.dumps({'socket':socket,'pane':'%0','baseURL':base}))
    # Simulate the test human accepting only this scratch folder and fake API key.
    # Never accept tool, channels, login or other permission prompts.
    while not stop.wait(.2):
        if a.agent=='claude':
            screen=run('capture-pane','-p','-t','%0')
            if 'Quick safety check:' in screen and str(project) in screen and 'Yes, I trust this folder' in screen:
                run('send-keys','-t','%0','Down','Enter'); time.sleep(.3)
            elif 'Do you want to use this API key?' in screen:
                run('send-keys','-t','%0','Up','Enter'); time.sleep(.3)
finally:
    subprocess.run([a.tmux,'-S',socket,'kill-server'],env=env,capture_output=True,timeout=8)
    server.shutdown(); server.server_close()
