#!/usr/bin/env python3
"""ST1: two real private Claude sessions on one real bridge; only the adopted assistant may talk to Zeus.
Private tmux, disposable HOME and config, localhost synthetic model. No user credentials or real agents touched."""
import json, pathlib, re, subprocess, sys, time
from LiveSupport import (REPO, Pane, Model, HostControl, eventually, finish_host_build, host_package, output_dir, scrub_paths, stop_host)
OUT = output_dir('st1-live')
REFUSAL = "Zeus only talks to its assistant. This session isn't it. Ask the user to pick this session in Zeus › Settings › Assistant, or stop calling Zeus tools."

def build_host():
    package = host_package(OUT, 'st1')
    sources = package/'Sources/Host'; sources.mkdir(parents=True, exist_ok=True)
    inputs = [REPO/'Zeus/App/Tests/Runtime/ST1RuntimeHost.swift', REPO/'Zeus/Shared/AppSeams.swift', REPO/'Zeus/Learn/Seams.swift', REPO/'Zeus/Cards/AttachmentTarget.swift', REPO/'Zeus/Cards/CardStore.swift', REPO/'Zeus/Cards/ContextSendIntent.swift', REPO/'Zeus/Cards/ThreadNotice.swift', REPO/'Zeus/Learn/PersistentRulesStore.swift']
    inputs += [p for area in ['Zeus/Bridge','Zeus/Agents','Zeus/Learn/Journal','Zeus/Learn/Redactor'] for p in (REPO/area).glob('*.swift') if p.name != 'DebugSpriteFrameCounter.swift']
    for path in inputs:(sources/path.name).write_text(path.read_text())
    (sources/'Seams.swift').unlink(missing_ok=True)
    products=','.join(f'.product(name: "{p}", package: "ZeusKit")' for p in ['ZeusProtocol','ZeusLink','ZeusSprites','ZeusDesign'])
    (package/'Package.swift').write_text('// swift-tools-version: 6.2\nimport PackageDescription\n'+f'let package = Package(name:"ST1Host", platforms:[.macOS(.v26)], dependencies:[.package(path:{json.dumps(str(REPO/"Packages/ZeusKit"))})], targets:[.executableTarget(name:"Host", dependencies:[{products}], swiftSettings:[.define("ST1_PROBE_HOST")])])\n')
    return finish_host_build(OUT,package)

def main():
    host=build_host(); pane=Pane('claude',prefix='zlv1_',output=OUT); process=None
    second=pane.home/'project2'; second.mkdir()
    calls=[]
    def action(body):
        messages=body.get('messages',[])
        last=messages[-1] if messages else {}
        content=last.get('content')
        if isinstance(content,list) and any(b.get('type')=='tool_result' for b in content): return None,{}
        if 'ST1 ping' in json.dumps(content):
            calls.append('zeus_say'); return 'zeus_say',{'text':'ST1 hello through Zeus'}
        return None,{}
    Model.action=action; Model.stage=0; Model.requests=[]; Model.completion_text='ST1 DONE'
    def tool_results():
        """The tool_result texts the real CLIs sent back to the model, decoded (never JSON-escaped)."""
        texts=[]
        for body in Model.requests:
            for message in body.get('messages',[]):
                if not isinstance(message.get('content'),list): continue
                for block in message['content']:
                    if block.get('type')!='tool_result': continue
                    content=block.get('content')
                    texts.append(content if isinstance(content,str) else ' '.join(part.get('text','') for part in content if isinstance(part,dict)))
        return texts
    def screen(target):
        return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',pane.tm('capture-pane','-p','-e','-t',target))
    def send(target,text):
        pane.tm('load-buffer','-b',target+'-input','-',input=text); pane.tm('paste-buffer','-p','-d','-b',target+'-input','-t',target)
        time.sleep(.15); pane.tm('send-keys','-t',target,'Enter')
    try:
        bridge=REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        config=pane.root/'mcp.json'
        config.write_text(json.dumps({'mcpServers':{'zeus':{'command':str(bridge),'args':['--agent','claude','--socket',str(pane.root/'bridge.sock')]}}}))
        log=(OUT/'host.log').open('w')
        process=subprocess.Popen([str(host),str(pane.root),pane.tmux],env=pane.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
        control=HostControl(process);control.read()
        argv=lambda base:[pane.cli,'--mcp-config',str(config),'--model','claude-haiku-4-5','--permission-mode','manual','--allowedTools','mcp__zeus__*']
        pane.start(Model,argv,lambda base:{'ANTHROPIC_API_KEY':'st1-local-fixture','ANTHROPIC_BASE_URL':base})
        pane.onboard()
        eventually(lambda:len(control.call('state')['sessions'])==1,'first real bridge connects',timeout=45)
        # The second session: same disposable home, its own folder, in a second window of the same private tmux server.
        for p in [pane.home/'.claude.json',pane.home/'.claude/.claude.json']:
            profile=json.loads(p.read_text()); profile.setdefault('projects',{})[str(second)]={'hasTrustDialogAccepted':True}; p.write_text(json.dumps(profile))
        launch2=pane.root/'launch2.py'
        launch2.write_text((pane.root/'launch.py').read_text().replace("'agent.pid'","'agent2.pid'").replace("agent.pid","agent2.pid").replace(str(pane.root/'exit'),str(pane.root/'exit2')))
        pane.tm('new-window','-d','-t','pc1','-n','pc2','-c',str(second),sys.executable,str(launch2))
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            s=screen('pc2')
            if 'Quick safety check:' in s and 'Yes, I trust this folder' in s: pane.tm('send-keys','-t','pc2','Down','Enter')
            elif 'Do you want to use this API key?' in s: pane.tm('send-keys','-t','pc2','Up','Enter')
            elif '❯' in s: break
            time.sleep(.2)
        else: raise TimeoutError('Second private Claude onboarding: '+screen('pc2'))
        state=eventually(lambda:(s if len((s:=control.call('state'))['sessions'])==2 else None),'second real bridge connects',timeout=45)
        first=[x for x in state['sessions'] if x['cwd']==str(pane.project)][0]['key']
        other=[x for x in state['sessions'] if x['cwd']==str(second)][0]['key']
        assert state['adopted']==first and state['assistantTarget']==first,state
        assert state['notices'] and state['notices'][0]['summary']==f'Talking to Claude in {pane.project}' and state['notices'][0]['primary']=='Change',state
        # The assistant posts; the other session is refused with the exact text and never reaches the thread.
        send('pc1','ST1 ping'); eventually(lambda:'ST1 DONE' in screen('pc1'),'assistant turn ends',timeout=45)
        send('pc2','ST1 ping'); eventually(lambda:'ST1 DONE' in screen('pc2'),'other turn ends',timeout=45)
        state=control.call('state')
        assert [c['session'] for c in state['cards']]==[first] and state['cards'][0]['body']=='ST1 hello through Zeus',state
        refused=[n for n in state['notices'] if n['summary'].startswith('Another session tried')]
        assert len(refused)==1 and refused[0]['summary']==f'Another session tried to reach Zeus: Claude in {second}',state
        assert refused[0]['primary']=='Make it my assistant' and refused[0]['secondary']=='Ignore',state
        texts=tool_results()
        assert any(REFUSAL in t for t in texts),texts
        # Once a day: a second refusal adds no line.
        send('pc2','ST1 ping'); eventually(lambda:screen('pc2').count('ST1 DONE')>=2,'second other turn ends',timeout=45)
        state=control.call('state')
        assert len([n for n in state['notices'] if n['summary'].startswith('Another session tried')])==1,state
        assert len(state['cards'])==1,state
        # "Make it my assistant" is the same as picking it in Settings.
        control.call('primary',id=refused[0]['id'])
        state=control.call('state'); assert state['picked']==other and state['assistantTarget']==other,state
        send('pc2','ST1 ping'); eventually(lambda:len(control.call('state')['cards'])==2,'picked session now posts',timeout=45)
        state=control.call('state')
        assert [c['session'] for c in state['cards']]==[first,other],state
        proof={'agent':pane.version,'isolation':'private tmux, disposable HOME/config, localhost synthetic model; no user credentials',
               'path':'two real Claude CLIs -> real zeus-mcp -> production ZeusRuntime admission',
               'tool_calls':calls,'refusal_received_by_other_session':any(REFUSAL in t for t in tool_results()),'state':state,
               'panes':{'assistant':screen('pc1'),'other':screen('pc2')}}
        proof=scrub_paths(proof,{str(pane.root):'/FIXTURE',str(REPO):'<worktree>'})
        target=REPO/'TestFixtures/live/st1';target.mkdir(parents=True,exist_ok=True)
        (target/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
        print(json.dumps({'passed':True,'agent':pane.version,'tool_calls':calls,'notices':[n['summary'] for n in state['notices']]}))
    finally:
        if process:stop_host(process)
        pane.close()
if __name__=='__main__':main()
