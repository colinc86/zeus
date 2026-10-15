#!/usr/bin/env python3
"""LG1/LM4: real managed Claude receives a digest and acknowledges it.
Private tmux, disposable HOME/config, synthetic localhost model and fixture key only.
"""
import argparse, json, pathlib, re, subprocess, time
from LiveSupport import (REPO, Pane, Model, HostControl, eventually, finish_host_build,
                         host_package, output_dir, scrub_paths, stop_host, start_model)
OUT = output_dir('lm4-live')
def build_host():
    package = host_package(OUT, 'lm4')
    sources = package/'Sources/Host'; sources.mkdir(parents=True, exist_ok=True)
    inputs = [REPO/'Zeus/App/Tests/Runtime/LM4RuntimeHost.swift', REPO/'Zeus/Shared/AppSeams.swift', REPO/'Zeus/Learn/Seams.swift', REPO/'Zeus/Cards/AttachmentTarget.swift', REPO/'Zeus/Cards/CardStore.swift', REPO/'Zeus/Cards/ContextSendIntent.swift', REPO/'Zeus/Cards/ThreadNotice.swift', REPO/'Zeus/Learn/PersistentRulesStore.swift']
    inputs += [p for area in ['Zeus/Bridge','Zeus/Agents','Zeus/Learn/Journal','Zeus/Learn/Redactor'] for p in (REPO/area).glob('*.swift') if p.name != 'DebugSpriteFrameCounter.swift']
    for path in inputs:(sources/path.name).write_text(path.read_text())
    # finish_host_build provides the seams; don't compile a duplicate copy.
    (sources/'Seams.swift').unlink(missing_ok=True)
    products=','.join(f'.product(name: "{p}", package: "ZeusKit")' for p in ['ZeusProtocol','ZeusLink','ZeusSprites','ZeusDesign'])
    (package/'Package.swift').write_text('// swift-tools-version: 6.2\nimport PackageDescription\n'+f'let package = Package(name:"LM4Host", platforms:[.macOS(.v26)], dependencies:[.package(path:{json.dumps(str(REPO/"Packages/ZeusKit"))})], targets:[.executableTarget(name:"Host", dependencies:[{products}], swiftSettings:[.define("LM4_PROBE_HOST")])])\n')
    return finish_host_build(OUT,package)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--agent',default='claude'); parser.add_argument('--quick',action='store_true'); parser.add_argument('--record',action='store_true'); args=parser.parse_args()
    assert args.agent=='claude'
    host=build_host(); pane=Pane('claude',prefix='zlv1_',output=OUT); process=None; seen=[]
    def action(body):
        rendered=json.dumps(body.get('messages',[]))
        if '[zeus delivery_id=lm4-digest' not in rendered:return None,{}
        steps=[('zeus_ack',{'delivery_ids':['lm4-digest']}),('zeus_say',{'text':'Synthetic learning received.'})]
        if len(seen)<len(steps):
            result=steps[len(seen)];seen.append(result[0]);return result
        return None,{}
    Model.action=action;Model.stage=0;Model.requests=[];Model.completion_text='LM4 ready'
    try:
        pane.server,pane.worker=start_model(Model)
        pane.env.update(ANTHROPIC_API_KEY='lm4-local-fixture',ANTHROPIC_BASE_URL=f'http://127.0.0.1:{pane.server.server_port}')
        profile={'hasCompletedOnboarding':True,'theme':'dark','hasAcknowledgedCostThreshold':True,'projects':{str(pane.project):{'hasTrustDialogAccepted':True}}}
        for p in [pane.home/'.claude.json',pane.home/'.claude/.claude.json']:p.write_text(json.dumps(profile))
        pane.version=subprocess.check_output([pane.cli,'--version'],env=pane.env,text=True,timeout=10).strip()
        bridge=REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        with (OUT/'host.log').open('w') as log:
            process=subprocess.Popen([str(host),str(pane.root),pane.tmux,pane.cli,str(bridge)],env=pane.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
            control=HostControl(process);control.read()
            def ready():
                state=control.call('state')
                if not state['pane']:return False
                target=state['pane']
                screen=pane.tm('capture-pane','-p','-t',target)
                if 'Quick safety check:' in screen and str(pane.project) in screen and 'Yes, I trust this folder' in screen:pane.tm('send-keys','-t',target,'Down','Enter')
                elif 'Do you want to use this API key?' in screen:pane.tm('send-keys','-t',target,'Up','Enter')
                return state if state['sessions']==1 and state['status']=='running(Zeus.ManagedScreenActivity.idle)' else (state if state['sessions']==1 and '.idle' in state['status'] else False)
            before=eventually(ready,'managed Claude idle',timeout=60)
            assert not before['receipts']
            control.call('digest')
            state=eventually(lambda:(s if (s:=control.call('state'))['deliveries'] and s['deliveries'][0]['acked'] and s['receipts'] else None),'digest -> model zeus_ack -> sent ledger',timeout=60)
            assert state['unread']==0 and len(state['deliveries'])==1 and state['deliveries'][0]['kind']=='learning' and state['deliveries'][0]['attempts']==1,state
            assert state['receipts'][0]['payload']['value']['text']=='Synthetic morning summary: working on a fixture project.',state
            assert state['receipts'][0]['payload']['value']['details']['sessionLabel']=='Claude · Zeus',state
            proof={'agent':pane.version,'tools':seen,'state':state,'model_received_digest':any('Synthetic morning summary: working on a fixture project.' in json.dumps(b.get('messages',[])) for b in Model.requests),'isolation':'private tmux, disposable HOME/config, localhost synthetic model, fixture encryption key'}
            assert proof['model_received_digest']
            proof=scrub_paths(proof,{str(pane.root):'/FIXTURE',str(REPO):'<worktree>'})
            (OUT/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
            if args.record:
                target=REPO/'TestFixtures/live/lm4';target.mkdir(parents=True,exist_ok=True);(target/'digest.json').write_text(json.dumps(proof,indent=2)+'\n')
            print(json.dumps({'passed':True,'agent':pane.version,'tools':seen}))
    finally:
        if process:stop_host(process)
        pane.close()
if __name__=='__main__':main()
