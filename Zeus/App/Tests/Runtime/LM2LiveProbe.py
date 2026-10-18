#!/usr/bin/env python3
"""LM2 reflection -> real private Claude -> actual rule tools. Synthetic, localhost, fixed test encryption key."""
import json, pathlib, re, subprocess, threading, time
from LiveSupport import (REPO, Pane, Model, HostControl, eventually, finish_host_build,
                         host_package, output_dir, scrub_paths, stop_host)
OUT = output_dir('lm2-live')

def build_host():
    package = host_package(OUT, 'lm2')
    sources = package/'Sources/Host'; sources.mkdir(parents=True, exist_ok=True)
    inputs = [REPO/'Zeus/App/Tests/Runtime/LM2RuntimeHost.swift', REPO/'Zeus/Shared/AppSeams.swift', REPO/'Zeus/Learn/Seams.swift', REPO/'Zeus/Cards/AttachmentTarget.swift', REPO/'Zeus/Cards/CardStore.swift', REPO/'Zeus/Cards/ContextSendIntent.swift', REPO/'Zeus/Cards/ThreadNotice.swift', REPO/'Zeus/Learn/PersistentRulesStore.swift']
    inputs += [p for area in ['Zeus/Bridge','Zeus/Agents','Zeus/Learn/Journal','Zeus/Learn/Redactor'] for p in (REPO/area).glob('*.swift') if p.name != 'DebugSpriteFrameCounter.swift']
    for path in inputs:(sources/path.name).write_text(path.read_text())
    # finish_host_build provides the seams; don't compile a duplicate copy.
    (sources/'Seams.swift').unlink(missing_ok=True)
    products=','.join(f'.product(name: "{p}", package: "ZeusKit")' for p in ['ZeusProtocol','ZeusLink','ZeusSprites','ZeusDesign'])
    (package/'Package.swift').write_text('// swift-tools-version: 6.2\nimport PackageDescription\n'+f'let package = Package(name:"LM2Host", platforms:[.macOS(.v26)], dependencies:[.package(path:{json.dumps(str(REPO/"Packages/ZeusKit"))})], targets:[.executableTarget(name:"Host", dependencies:[{products}], swiftSettings:[.define("LM2_PROBE_HOST")])])\n')
    return finish_host_build(OUT,package)

def main():
    host=build_host(); pane=Pane('claude',prefix='zlv1_',output=OUT); process=None
    seen=[]
    def action(body):
        rendered=json.dumps(body.get('messages',[]))
        match=re.search(r'd_reflection_[0-9]{8}',rendered)
        if not match:return None,{}
        targets=[('zeus_get_rules',{}),('zeus_propose_rules',{'rules':[
            {'sentence':'Keep routine updates quiet while tests are failing','trigger':{'state':'tests failing'},'kind':'passive','evidence':['synthetic-editor','synthetic-editor-yesterday']},
            {'sentence':'Send a short recap after work','kind':'acts','evidence':['synthetic-editor','synthetic-editor-yesterday']}]}),
            ('zeus_ack',{'delivery_ids':[match.group(0)]}),('zeus_say',{'text':'Reflection fixture processed.'})]
        if len(seen)<len(targets):
            next_call=targets[len(seen)];seen.append(next_call[0]);return next_call
        return None,{}
    Model.action=action; Model.stage=0;Model.requests=[];Model.completion_text='LM2 reflection complete'
    try:
        bridge=REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        config=pane.root/'mcp.json'
        config.write_text(json.dumps({'mcpServers':{'zeus':{'command':str(bridge),'args':['--agent','claude','--socket',str(pane.root/'bridge.sock')]}}}))
        log=(OUT/'host.log').open('w')
        process=subprocess.Popen([str(host),str(pane.root),pane.tmux],env=pane.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
        control=HostControl(process);control.read()
        pane.start(Model,lambda base:[pane.cli,'--mcp-config',str(config),'--model','claude-haiku-4-5','--permission-mode','manual','--allowedTools','mcp__zeus__*'],lambda base:{'ANTHROPIC_API_KEY':'lm2-local-fixture','ANTHROPIC_BASE_URL':base})
        pane.onboard()
        eventually(lambda:control.call('state')['sessions']==1,'real bridge connects',timeout=45)
        pane.send('Begin the isolated reflection fixture.')
        eventually(lambda:'LM2 reflection complete' in pane.plain(),'native warmup ends',timeout=45)
        control.call('reflect')
        state=eventually(lambda:(s if len((s:=control.call('state'))['rules'])==2 and s['deliveries'] and s['deliveries'][0]['acked'] else None),'reflection -> actual propose_rules -> ack',timeout=60)
        assert [r['status'] for r in state['rules']]==['active','shadow'],state
        assert len(state['receipts'])==1 and state['receipts'][0]['payload']['value']['text']==state['reflectionTexts'][0],state
        assert state['receipts'][0]['payload']['value']['details']['sessionLabel']=='Claude · Assistant',state
        assert len(state['deliveries'])==1 and state['deliveries'][0]['kind']=='reflection' and state['deliveries'][0]['acked'] and state['deliveries'][0]['attempts']==1,state
        control.call('reflect');time.sleep(.25)
        assert len(control.call('state')['deliveries'])==1
        proof={'agent':pane.version,'isolation':'private tmux, disposable HOME/config, localhost synthetic model, fixed test key; no user credentials',
               'path':'production ZeusRuntime -> production TmuxConnector -> real Claude -> real zeus-mcp -> production rules store',
               'tools':seen,'state':state,'pane':pane.snapshot(),'model_received_reflection':any('Zeus reflection for Wednesday 14 October' in json.dumps(b.get('messages',[])) for b in Model.requests)}
        assert proof['model_received_reflection']
        proof=scrub_paths(proof,{str(pane.root):'/FIXTURE',str(REPO):'<worktree>'})
        target=REPO/'TestFixtures/live/lm2';target.mkdir(parents=True,exist_ok=True)
        (target/'reflection.json').write_text(json.dumps(proof,indent=2)+'\n')
        print(json.dumps({'passed':True,'agent':pane.version,'tools':seen,'statuses':[r['status'] for r in state['rules']]}))
    finally:
        if process:stop_host(process)
        pane.close()
if __name__=='__main__':main()
