#!/usr/bin/env python3
"""PC1 real private CLI captures; localhost models, disposable HOME, no human config.
Run from the worktree root: python3 -B Zeus/App/Tests/Runtime/PC1LiveScreens.py
--record writes scrubbed ANSI/cursor fixtures. Raw evidence stays in build/pc1-live.
"""
import argparse, datetime, http.server, importlib.util, json, os, pathlib, re, shutil, signal, subprocess, sys, tempfile, threading, time
from AC1LiveProbe import Model, eventually
REPO=pathlib.Path(__file__).resolve().parents[4]
OUT=REPO/'build/pc1-live';OUT.mkdir(parents=True,exist_ok=True)
UPDATE='✔ Update installed · Restart to update'
DRAFT='The sample item was handled earlier.\nKeep this second line as an unsent draft.'
class Pane:
    def __init__(self,agent,native_updater=False):
        self.agent=agent;self.root=pathlib.Path(tempfile.mkdtemp(prefix='zpc1_',dir='/tmp')).resolve()
        self.home=self.root/'home';self.project=self.root/'project';self.home.mkdir();self.project.mkdir()
        for d in ['.claude','.codex','.config','.cache','.local/share','.local/state','tmux']:(self.home/d).mkdir(parents=True)
        self.socket=str(self.root/'tmux.sock');self.tmux=shutil.which('tmux');self.cli=shutil.which(agent)
        assert self.tmux and self.cli
        self.native_updater=native_updater
        if native_updater:
            version=subprocess.check_output([self.cli,'--version'],text=True,timeout=10).split()[0]
            binary=self.home/'.local/share/claude/versions'/version;binary.parent.mkdir(parents=True)
            shutil.copy2(pathlib.Path(self.cli).resolve(),binary)
            launch=self.home/'.local/bin/claude';launch.parent.mkdir(parents=True);launch.symlink_to(binary)
            assert launch.resolve().is_relative_to(self.home)
            self.cli=str(launch)
        self.env={'HOME':str(self.home),'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin','TERM':'xterm-256color','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8','USER':'fixture','LOGNAME':'fixture',
            'CLAUDE_CONFIG_DIR':str(self.home/'.claude'),'CODEX_HOME':str(self.home/'.codex'),'XDG_CONFIG_HOME':str(self.home/'.config'),'XDG_DATA_HOME':str(self.home/'.local/share'),'XDG_CACHE_HOME':str(self.home/'.cache'),'XDG_STATE_HOME':str(self.home/'.local/state'),
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','CLAUDE_CODE_DISABLE_AUTO_MEMORY':'1','DISABLE_AUTOUPDATER':'1','ENABLE_TOOL_SEARCH':'false',
            'OPENCODE_DISABLE_AUTOUPDATE':'true','OPENCODE_DISABLE_EXTERNAL_PLUGINS':'true','OPENCODE_DISABLE_MODELS_FETCH':'true','OPENCODE_DISABLE_LSP_DOWNLOAD':'true'}
        self.server=None;self.worker=None;self.captures=[]
        if native_updater:
            self.env.pop('DISABLE_AUTOUPDATER');self.env.pop('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')
    def tm(self,*args,input=None):
        return subprocess.run([self.tmux,'-u','-S',self.socket,'-f','/dev/null',*args],env=self.env,input=input,capture_output=True,text=True,check=True,timeout=10).stdout
    def snapshot(self):
        return {'screen':self.tm('capture-pane','-p','-e','-t','pc1'), 'inputMetadata':self.tm('display-message','-p','-t','pc1','#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_dead}|#{cursor_flag}|#{bracket_paste_flag}').strip()}
    def plain(self):return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',self.snapshot()['screen'])
    def capture(self,name,provenance):
        raw=self.snapshot();(OUT/(name+'.raw.json')).write_text(json.dumps(raw,indent=2))
        public=dict(raw,agent=self.agent,version=self.version,provenance=provenance)
        public['screen']=public['screen'].replace(str(self.root),'/FIXTURE')
        self.captures.append((name,public));return public
    def start(self,handler,argv,env):
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
        self.worker=threading.Thread(target=self.server.serve_forever,daemon=True);self.worker.start()
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
            try:(OUT/(self.agent+'-final.json')).write_text(json.dumps(self.snapshot(),indent=2))
            except subprocess.SubprocessError:pass
        subprocess.run([self.tmux,'-S',self.socket,'kill-server'],env=self.env,capture_output=True,timeout=10)
        if (self.root/'agent.pid').exists():eventually(lambda:(self.root/'exit').exists(),'Owned CLI did not exit',timeout=6)
        if self.server:self.server.shutdown();self.server.server_close();self.worker.join(timeout=2)
        shutil.rmtree(self.root)

def claude_screens(native_updater=False):
    p=Pane('claude',native_updater);mode={'value':'idle','scheduled':False};release=threading.Event();work_started=threading.Event()
    settings=p.home/'.claude/settings.json';footer=p.root/'footer.txt';footer.write_text('')
    # Claude itself renders this configured status line, not an edited terminal capture.
    status=p.root/'statusline.py';status.write_text(f'import pathlib,sys\nsys.stdin.read()\nprint(pathlib.Path({str(footer)!r}).read_text(),end="")\n')
    config={'permissions':{'ask':['Bash']},'statusLine':{'type':'command','command':sys.executable+' '+str(status),'refreshInterval':1}}
    settings.write_text(json.dumps(config))
    Model.stage=0;Model.requests=[];Model.results=[];Model.completion_text='PC1 fixture complete.'
    def action(body):
        texts=[m.get('content') for m in body.get('messages',[]) if isinstance(m.get('content'),str)]
        texts += [b.get('text','') for m in body.get('messages',[]) if isinstance(m.get('content'),list) for b in m['content'] if b.get('type')=='text']
        last=' '.join(texts[-1:])
        if mode['value']=='working':work_started.set();release.wait(timeout=30)
        if mode['value']=='permission' and 'PC1_PERMISSION' in last:return 'Bash',{'command':'printf PC1_DONE > pc1.txt','description':'Write the scratch fixture file'}
        if mode['value']=='schedule' and 'PC1_CREATE_SCHEDULE' in last and not mode['scheduled']:
            mode['scheduled']=True
            when=datetime.datetime.now()+datetime.timedelta(minutes=1)
            if when.minute in [0,30]:when+=datetime.timedelta(minutes=1)
            return 'CronCreate',{'cron':f'{when.minute} {when.hour} * * *','prompt':'PC1_SCHEDULED_FIXTURE','recurring':False,'durable':False}
        if 'PC1_SCHEDULED_FIXTURE' in last:Model.completion_text=''
        return None,{}
    Model.action=action
    try:
        p.start(Model,lambda _: [p.cli,'--model','claude-haiku-4-5','--permission-mode','manual','--allowedTools','CronCreate'],lambda base:{'ANTHROPIC_BASE_URL':base,'ANTHROPIC_API_KEY':'pc1-local-fixture'})
        p.onboard();p.send('PC1_IDLE: finish a short turn.')
        eventually(lambda:'PC1 fixture complete.' in p.plain(),'Claude first turn never ended')
        eventually(lambda:'done ' in p.plain(),'Claude completion summary missing')
        p.capture('claude-idle','Real Claude completed a localhost-model turn. Default empty status line.')
        p.send(DRAFT,submit=False);p.capture('claude-draft','Real bracketed paste of two unsent lines into Claude composer; Enter not sent.')
        p.tm('send-keys','-t','pc1','C-c');eventually(lambda:'The sample item' not in p.plain(),'Scratch draft was not cleared')
        if not native_updater:footer.write_text(UPDATE+'\n')
        eventually(lambda:'Update installed' in p.plain() and 'Restart to update' in p.plain(),'Native update footer did not render' if native_updater else 'Status-line update-copy fixture did not render',timeout=180)
        footer_source='Native updater notice from updating only the throwaway HOME copy of Claude.' if native_updater else 'Real Claude statusLine renders exact update-copy text from a scratch script; no updater or installed binary is modified.'
        p.capture('claude-update-idle',footer_source)
        mode['value']='schedule';p.send('PC1_CREATE_SCHEDULE: schedule the private fixture.')
        eventually(lambda:'next run' in p.plain() or 'scheduled' in p.plain().lower(),'CronCreate did not complete')
        mode['value']='idle'
        eventually(lambda:'Running scheduled task (' in p.plain(),'Native one-shot scheduled task did not fire',timeout=125)
        eventually(lambda:any('PC1_SCHEDULED_FIXTURE' in json.dumps(b.get('messages',[])) for b in Model.requests),'Scheduled turn never reached local model')
        time.sleep(1);p.capture('claude-scheduled-idle','Real native CronCreate one-shot fires in the private session; localhost model returns no text.')
        mode['value']='working';p.send('PC1_WORK: wait for the fixture release.')
        eventually(work_started.is_set,'Working request never reached local model')
        time.sleep(.5);p.capture('claude-update-working','Real Claude active turn waiting on localhost model. '+footer_source)
        release.set();mode['value']='idle';time.sleep(1)
        mode['value']='permission';p.send('PC1_PERMISSION: ask before writing the fixture file.')
        eventually(lambda:'Do you want to proceed?' in p.plain(),'Real Bash permission dialog did not appear')
        p.capture('claude-update-permission','Real native Bash permission widget after update. Claude hides the native updater badge while this modal is open; capture is unchanged.')
        (OUT/'claude-model-requests.json').write_text(json.dumps(Model.requests,indent=2))
        return p.captures
    finally:release.set();p.close();Model.action=None;Model.completion_text=None

def other_draft(agent):
    p=Pane(agent)
    spec=importlib.util.spec_from_file_location('fixture',REPO/'TestFixtures/models/permission_model.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    try:
        def env(base):
            if agent=='codex':return {}
            return {'OPENCODE_CONFIG_CONTENT':json.dumps({'autoupdate':False,'share':'disabled','model':'openai/gpt-4.1-mini','enabled_providers':['openai'],'provider':{'openai':{'options':{'baseURL':base+'/v1','apiKey':'pc1-local-fixture'}}},'experimental':{'disable_paste_summary':True}})}
        def args(base):
            if agent=='opencode':return [p.cli,str(p.project)]
            overrides=['check_for_update_on_startup=false','model="pc1"','model_provider="pc1"',f'model_providers.pc1={{name="PC1 fixture",base_url="{base}/v1",wire_api="responses",requires_openai_auth=false}}',f'projects.{json.dumps(str(p.project))}.trust_level="trusted"']
            return [p.cli,'--no-daemon','-s','read-only','-a','on-request',*[v for o in overrides for v in ['-c',o]]]
        p.start(m.Model,args,env);p.onboard();time.sleep(.4);p.send('PC1 unsent draft.',submit=False)
        eventually(lambda:'PC1 unsent draft.' in p.plain(),'Draft was not rendered')
        p.capture(agent+'-draft','Real native idle composer with deliberately pasted unsent text; Enter not sent.')
        return p.captures
    finally:p.close()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--record',action='store_true');parser.add_argument('--agent',choices=['all','claude','codex','opencode'],default='all');parser.add_argument('--native-updater',action='store_true',help='Enable updates only for an isolated copy of Claude under the disposable HOME');a=parser.parse_args()
    if a.record and a.agent in ['all','claude'] and not a.native_updater:
        parser.error('Recording Claude update fixtures requires --native-updater; a scratch status-line copy is not native update evidence.')
    captures=[]
    if a.agent in ['all','claude']:captures+=claude_screens(a.native_updater)
    for agent in ['codex','opencode']:
        if a.agent in ['all',agent]:captures+=other_draft(agent)
    target=REPO/'TestFixtures/panes/claude-2.1';target.mkdir(parents=True,exist_ok=True)
    for name,data in captures:
        print(json.dumps({'fixture':name,'version':data['version'],'inputMetadata':data['inputMetadata']}),flush=True)
        if a.record:(target/(name+'.json')).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__':main()
