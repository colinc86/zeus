#!/usr/bin/env python3
"""Local-only model and disposable agent profiles for S3 resume verification."""
import argparse, http.server, json, pathlib, signal, threading, time, uuid
p = argparse.ArgumentParser()
p.add_argument('--root', required=True)
p.add_argument('--agent', required=True)
a = p.parse_args()
root = pathlib.Path(a.root)
assert root.name.startswith('zs3_') and root.parent.resolve() == pathlib.Path('/private/tmp')
assert not root.is_symlink() and a.agent in ('claude', 'codex', 'opencode')
home = root / 'home'
project = root / 'project'
for d in ['.claude', '.codex', '.config/opencode', '.cache', '.local/share', '.local/state', 'tmux']:
    (home / d).mkdir(parents=True, exist_ok=True)
project.mkdir(exist_ok=True)
lock = threading.Lock()
policy_sent = False
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
        global policy_sent
        names = [tool.get('function', tool).get('name') for tool in body.get('tools', [])]
        policy_probe = a.agent == 'opencode' and 'S3_POLICY_PROBE' in json.dumps(body)
        emit_policy = policy_probe and not policy_sent and 'bash' in names
        if emit_policy:
            policy_sent = True
            (root / 'policy-tool.json').write_text(json.dumps({'tool': 'bash'}))
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        def event(v,name=None):
            self.wfile.write(((('event: '+name+'\n') if name else '')+'data: '+json.dumps(v)+'\n\n').encode()); self.wfile.flush()
        try:
            if emit_policy:
                arguments = json.dumps({'command': 'printf S3_POLICY_ALLOWED > s3-policy.txt', 'description': 'Write the private S3 policy fixture'})
                if self.path.split('?')[0].endswith('/chat/completions'):
                    chunk = {'id':'chat_s3_policy','object':'chat.completion.chunk','created':int(time.time()),'model':body.get('model','fixture'),'choices':[{'index':0,'delta':{'tool_calls':[{'index':0,'id':'call_s3_policy','type':'function','function':{'name':'bash','arguments':arguments}}]},'finish_reason':None}]}
                    event(chunk); chunk['choices'][0]={'index':0,'delta':{},'finish_reason':'tool_calls'}; event(chunk)
                    self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
                else:
                    item = {'id':'fc_s3_policy','type':'function_call','name':'bash','call_id':'call_s3_policy','arguments':arguments,'status':'completed'}
                    response = {'id':'resp_s3_policy','object':'response','created_at':int(time.time()),'status':'completed','model':'fixture','output':[item],'error':None,'incomplete_details':None,'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
                    event({'type':'response.created','response':dict(response,status='in_progress',output=[])})
                    event({'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress')})
                    event({'type':'response.output_item.done','output_index':0,'item':item})
                    event({'type':'response.completed','response':response})
                return
            if a.agent=='claude':
                msg={'id':'msg_'+uuid.uuid4().hex,'type':'message','role':'assistant','model':body.get('model','fixture'),'content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}}
                event({'type':'message_start','message':msg},'message_start')
                event({'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}},'content_block_start')
                event({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'S3_READY'}},'content_block_delta')
                event({'type':'content_block_stop','index':0},'content_block_stop')
                event({'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':1}},'message_delta')
                event({'type':'message_stop'},'message_stop')
            elif self.path.split('?')[0].endswith('/chat/completions'):
                chunk={'id':'chat_n1','object':'chat.completion.chunk','created':int(time.time()),'model':body.get('model','n1'),'choices':[{'index':0,'delta':{'role':'assistant','content':'S3_READY'},'finish_reason':None}]}
                event(chunk); chunk['choices'][0]={'index':0,'delta':{},'finish_reason':'stop'}; event(chunk); self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
            else:
                item={'id':'msg_'+uuid.uuid4().hex,'type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'S3_READY','annotations':[]}]}
                response={'id':'resp_'+uuid.uuid4().hex,'object':'response','created_at':int(time.time()),'status':'completed','model':'n1','output':[item],'error':None,'incomplete_details':None,'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
                event({'type':'response.created','response':dict(response,status='in_progress',output=[])})
                event({'type':'response.output_item.added','output_index':0,'item':dict(item,status='in_progress')})
                event({'type':'response.content_part.added','item_id':item['id'],'output_index':0,'content_index':0,'part':{'type':'output_text','text':'','annotations':[]}})
                event({'type':'response.output_text.delta','item_id':item['id'],'output_index':0,'content_index':0,'delta':'S3_READY'})
                event({'type':'response.output_item.done','output_index':0,'item':item}); event({'type':'response.completed','response':response})
        except (BrokenPipeError,ConnectionResetError): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
base = 'http://127.0.0.1:' + str(server.server_port)
profile = {'hasCompletedOnboarding': True, 'theme': 'dark', 'hasAcknowledgedCostThreshold': True}
for path in [home / '.claude.json', home / '.claude/.claude.json']:
    path.write_text(json.dumps(profile))
(home / '.codex/config.toml').write_text('check_for_update_on_startup=false\nmodel="s3"\nmodel_provider="s3"\n[model_providers.s3]\nname="S3 localhost fixture"\nbase_url="'+base+'/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[projects.'+json.dumps(str(project))+']\ntrust_level="trusted"\n')
(home / '.config/opencode/opencode.json').write_text(json.dumps({'autoupdate':False, 'share':'disabled', 'model':'openai/gpt-4.1-mini', 'enabled_providers':['openai'], 'provider':{'openai':{'options':{'baseURL':base+'/v1', 'apiKey':'s3-local-fixture'}}}}))
(root / 'ready.json').write_text(json.dumps({'baseURL':base}))
stop = threading.Event()
for sig in [signal.SIGTERM, signal.SIGINT]:
    signal.signal(sig, lambda *_: stop.set())
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    stop.wait()
finally:
    server.shutdown()
    server.server_close()
