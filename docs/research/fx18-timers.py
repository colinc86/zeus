#!/usr/bin/env python3
"""Run from the worktree root after build.sh, with the exclusive heavy slot.
Uses SA2's private HOME/socket/localhost model; copies a diagnostic host only
under build/tmp/fx18. Never reads the real agent configuration or credentials.
"""
import io,json,os,pathlib,sys,time
root=pathlib.Path.cwd()
sys.path.insert(0,str(root/'Zeus/App/Tests/Runtime'))
os.environ['ZEUS_LIVE_OUTPUT']=str(root/'build/tmp/fx18/timers')
import SA2LiveProbe as p
from LiveSupport import serialize_live_hosts

def host_package(out, name):
    serialize_live_hosts()
    package = root / 'build/tmp/fx18/timer-host'
    package.mkdir(parents=True, exist_ok=True)
    if (package / 'Sources').exists(): p.shutil.rmtree(package / 'Sources')
    return package
p.host_package = host_package
original_copy=p.shutil.copyfile
def copy(source,dest,*args,**kw):
    result=original_copy(source,dest,*args,**kw)
    if pathlib.Path(source).name=='SA2RuntimeHost.swift':
        target=pathlib.Path(dest)
        target.write_text(target.read_text().replace('case "stop": controller.stopManagedSession()', 'case "restart": controller.restartManagedSession()\n                                case "stop": controller.stopManagedSession()'))
        target.write_text(target.read_text().replace('at: args.count - 1)', 'at: args.firstIndex(of: "resume") ?? (args.count - 1))'))
    return result
p.shutil.copyfile=copy
original_post=p.Model.do_POST
catalogs=[]
def post(self):
    body=self.rfile.read(int(self.headers.get('Content-Length',0)))
    payload=json.loads(body)
    catalogs.append(payload.get('tools',[]))
    (p.OUT/'catalogs.json').write_text(json.dumps(catalogs,indent=2))
    self.rfile=io.BytesIO(body)
    return original_post(self)
p.Model.do_POST=post
executable=p.build_host()
results=[]
for agent in ['codex','opencode']:
    catalogs.clear()
    probe=p.Probe(executable,agent)
    try:
        probe.wait(lambda: probe.state()['managed'].endswith('.idle)'), 'initial idle',timeout=90)
        probe.wait(lambda: bool(catalogs), 'initial model catalog')
        before=json.loads((probe.root/'managed.json').read_text())
        count=len(catalogs)
        (p.OUT/(agent+'-before.json')).write_text(json.dumps(before,indent=2))
        probe.call('restart')
        probe.wait(lambda: (json.loads((probe.root/'managed.json').read_text()).get('pane') or {}).get('pid') not in (None,before['pane']['pid']), 'new pane',timeout=45)
        probe.wait(lambda: probe.state()['managed'].endswith('.idle)'), 'resumed idle',timeout=90)
        # Resume need not generate a model turn on its own. Wake only this owned pane.
        pane=probe.state()['pane']
        probe.tm('send-keys','-t',pane,'-l','SA2_READY_CONTINUE')
        time.sleep(.5)
        probe.tm('send-keys','-t',pane,'Enter')
        probe.wait(lambda: len(catalogs)>count, 'post-resume model catalog',timeout=45)
        probe.wait(lambda: probe.state()['sessions']>0, 'post-resume bridge',timeout=45)
        probe.call('send',text='SA2_SAY',id='d_sa2_say')
        probe.wait(lambda: any(c['body']=='SA2_SAY native bridge reply.' for c in probe.state()['cards']), 'resumed native tools',timeout=60)
        after=json.loads((probe.root/'managed.json').read_text())
        names=set()
        for catalog in catalogs:
            for tool in catalog:
                if tool.get('type')=='namespace':
                    names.update(t.get('name','') for t in tool.get('tools',[]))
                else:names.add(tool.get('function',tool).get('name',''))
        results.append({'agent':agent,'version':probe.version,'native_conversation_before':before.get('conversation'),'native_conversation_after':after.get('conversation'),'requests_before_restart':count,'requests_after_restart':len(catalogs)-count,'tools':sorted(names),'resumed_zeus_say':True})
        (p.OUT/'timers.json').write_text(json.dumps(results,indent=2))
    except Exception as error:
        (p.OUT/(agent+'-failure.json')).write_text(json.dumps({'error':str(error),'snapshot':probe.snapshot('failure'),'record':json.loads((probe.root/'managed.json').read_text()),'catalogs':catalogs},indent=2))
        results.append({'agent':agent,'version':probe.version,'error':str(error)})
    finally:probe.close()
print(json.dumps(results,indent=2))

if any(r.get("error") for r in results): raise SystemExit(1)

summary = []
for result in results:
    before = result['native_conversation_before']['nativeID']
    after = result['native_conversation_after']['nativeID']
    assert before and before == after
    summary.append(dict(agent=result['agent'], version=result['version'],
        same_native_conversation=True, resumed_zeus_say=result['resumed_zeus_say'],
        tools=[name for name in result['tools'] if name]))
(p.OUT / 'timers-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
