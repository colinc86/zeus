"""Reproducible native scroll benchmark; artifacts and traces stay in this worktree's build/."""
import argparse, datetime, json, os, pathlib, plistlib, subprocess, tempfile, time, uuid, shutil

root = pathlib.Path(__import__('sys').argv[1])
p = argparse.ArgumentParser()
p.add_argument('--label', default='baseline')
p.add_argument('--unrecorded', action='store_true', help='validate the driver without Instruments; never a hitch measurement')
p.add_argument('--configuration', choices=['baseline','opaque-panel','single-frame','avatar-paused','sf-mono','local-events'], default='baseline')
p.add_argument('--output', type=pathlib.Path)
p.add_argument('--template', default='Animation Hitches')
p.add_argument('--app', type=pathlib.Path, default=root/'build/DerivedData/Build/Products/Debug/Zeus.app')
a = p.parse_args(__import__('sys').argv[2:])
a.label=''.join(c if c.isalnum() or c in '-_' else '_' for c in a.label)
a.app=a.app.resolve()
if not a.app.is_relative_to(root.resolve()/'build'): p.error('--app must be inside this worktree’s build/')
result = a.output.resolve() if a.output else root/'build/scroll-perf'/(datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+a.label)
if not result.is_relative_to(root.resolve()/'build'): p.error('--output must be inside this worktree’s build/')
result.mkdir(parents=True)
if not a.unrecorded and shutil.disk_usage(result).free < 20 * 1024**3:
    p.error('Animation Hitches needs at least 20 GiB free for staging and saving; preserve exports when pruning old traces')
recorder_temporary = result/'recorder-tmp'
recorder_temporary.mkdir()
children = []
owned_staging = {}
def remember_staging(recorder):
    # Instruments ignores TMPDIR for its kernel staging stream on some macOS versions.
    # Record only files proven open by OUR recorder PID, never scan/delete another run's files.
    output = subprocess.run(['lsof', '-p', str(recorder.pid), '-Fn'], capture_output=True, text=True)
    for line in output.stdout.splitlines():
        if not line.startswith('n'): continue
        path = pathlib.Path(line[1:])
        if not (path.name.startswith('instruments') and path.suffix == '.ktrace'): continue
        if path.parent.resolve() != pathlib.Path(tempfile.gettempdir()).resolve() and not path.is_relative_to(recorder_temporary): continue
        try:
            stat = path.stat()
            if stat.st_uid == os.getuid(): owned_staging[path] = stat.st_ino
        except FileNotFoundError: pass
with tempfile.TemporaryDirectory(prefix='zscroll_', dir='/private/tmp') as temporary_home:
    home = pathlib.Path(temporary_home)
    support = home/'Library/Application Support/Zeus'; support.mkdir(parents=True)
    fixture = home/'fixtures'; fixture.mkdir(); (fixture/'report.md').write_text('Benchmark attachment.\n')
    variants = [
        'A short update from your assistant. The next step is ready for your review.',
        '## Current plan\n\n**Completed:** indexing and validation.\n\n- Check the inputs\n- Review the proposed changes\n- Share the final result',
        '1. Read the configuration\n2. Run the checks\n3. Save the output\n\nA paragraph after the list with **bold** and *italic* text.',
        '```swift\nstruct Result {\n    let count: Int\n    func report() -> String {\n        "Processed \\(count) records"\n    }\n}\n```\nThe implementation keeps the existing interface.',
        '> The earlier review requested a smaller, clearer change.\n\nHere is a [reference](https://example.com) and `inline code` for context.',
        'The report and project folder are ready. Review both before continuing.',
        'Thanks. Continue with the next step and send me a short update.',
        '## Review\n\nA longer paragraph with enough text to wrap across several lines in this narrow panel. We checked the main path and the recovery path, and the results agree.\n\n- **First:** preserve the original data\n- **Second:** verify the new output\n- **Third:** explain the result clearly.']
    cards=[]
    for i in range(200):
        stamp=(datetime.datetime(2026,10,12,12,tzinfo=datetime.timezone.utc)+datetime.timedelta(seconds=i*35)).isoformat().replace('+00:00','Z')
        agent=['claude','codex','opencode'][(i//8)%3]; folder=['Website','Zeus','Research'][(i//8)%3]
        card=dict(id=f'c_scroll_{i:03}',kind='userMessage' if i%8==6 else 'content' if i%8==5 else 'message',
                  body=variants[i%8], title=f'Update {i+1}' if i%5==0 else None,
                  options=[], attachments=[], priority='normal', createdAt=stamp, updatedAt=stamp,
                  status='answered' if i%8==6 else 'dismissed', sessionKey=f'{agent}:/work/{folder}#100{i}.1791826000000000')
        if i%8==5: card['attachments']=[dict(id=f'a_{i}',kind='file',label=f'Review report {i+1}.md',target=str(fixture/'report.md')),
                                          dict(id=f'b_{i}',kind='folder',label='Project folder',target=str(fixture))]
        cards.append({k:v for k,v in card.items() if v is not None})
    snapshot=dict(version=1,cards=cards,seenIDs=[c['id'] for c in cards],revealedIDs=[c['id'] for c in cards])
    (support/'cards.json').write_text(json.dumps(snapshot)); (result/'fixture.json').write_text(json.dumps(snapshot,indent=2))
    with (a.app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
    prefs=home/'Library/Preferences';prefs.mkdir(parents=True)
    settings={'general.welcomeShown':True,'general.typewriter':False,'general.sound':False,'quiet.enabled':False,
              'appearance.font':'system' if a.configuration == 'sf-mono' else 'pixel',
              'general.talkHotKey':json.dumps(dict(key='Z',command=True,option=True,control=False,shift=False,enabled=False)).encode()}
    with (prefs/(info['CFBundleIdentifier']+'.plist')).open('wb') as f: plistlib.dump(settings,f)
    env=dict({k:v for k,v in os.environ.items() if k in ["PATH","HOME","TMPDIR","USER","LOGNAME","LANG","LC_ALL","__CF_USER_TEXT_ENCODING"]},CFFIXED_USER_HOME=str(home),ZEUS_PERF_DIAGNOSTICS='1',ZEUS_PERF_IGNORE_OCCLUSION='1',ZEUS_PERF_PANEL='conversation',ZEUS_PERF_SCROLL='1',ZEUS_PERF_OPAQUE_PANEL=str(int(a.configuration == 'opaque-panel')),ZEUS_PERF_SINGLE_FRAME=str(int(a.configuration == 'single-frame')),ZEUS_PERF_PAUSE_AVATAR=str(int(a.configuration == 'avatar-paused')),ZEUS_PERF_INPUT='local-events' if a.configuration == 'local-events' else 'clip')
    env.pop('XCTestConfigurationFilePath',None)
    try:
        with (result/'app.log').open('wb') as log:
            app=subprocess.Popen([str(a.app/'Contents/MacOS'/info['CFBundleExecutable'])],env=env,stdout=log,stderr=log)
            children.append(app)
            deadline=time.monotonic()+15
            while not (support/'bridge.sock').exists():
                if app.poll() is not None or time.monotonic()>deadline: raise RuntimeError('App startup failed; inspect app.log')
                time.sleep(.1)
            time.sleep(4)
            ready_path=home/'scroll-ready.json'
            deadline=time.monotonic()+15
            while not ready_path.exists():
                if app.poll() is not None or time.monotonic()>deadline: raise RuntimeError('App did not publish benchmark readiness')
                time.sleep(.1)
            readiness=json.loads(ready_path.read_text())
            (result/'readiness.json').write_text(json.dumps(readiness,indent=2)+'\n')
            if not readiness['ready']: raise RuntimeError('No valid rendered measurement: '+readiness['reason'])
            trace=result/'scroll.trace'
            with (result/'xctrace.log').open('w') as trace_log:
                recorder = None
                if not a.unrecorded:
                    notification='dev.zeus.scroll-ready.'+uuid.uuid4().hex
                    ready=subprocess.Popen(['/usr/bin/notifyutil','-1',notification],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    children.append(ready)
                    time.sleep(.2)
                    recorder=subprocess.Popen(['xcrun','xctrace','record','--template',a.template,'--attach',str(app.pid),
                                               '--time-limit','200s','--output',str(trace),'--no-prompt','--notify-tracing-started',notification],stdout=trace_log,stderr=trace_log, env=dict(os.environ, TMPDIR=str(recorder_temporary)+"/"))
                    children.append(recorder)
                    deadline=time.monotonic()+90
                    while ready.poll() is None:
                        if recorder.poll() is not None or time.monotonic()>deadline: raise RuntimeError('xctrace did not start; inspect xctrace.log')
                        time.sleep(.1)
                    if ready.returncode: raise RuntimeError('Tracing-start notification waiter failed')
                    remember_staging(recorder)
                (home/'scroll-start').touch()
                deadline=time.monotonic()+190
                while not (home/'scroll-result.json').exists():
                    if recorder is not None and recorder.poll() is not None: raise RuntimeError('Recording ended before traversal; inspect xctrace.log')
                    if app.poll() is not None or time.monotonic()>deadline: raise RuntimeError('Scroll benchmark did not finish')
                    time.sleep(.2)
                run=json.loads((home/'scroll-result.json').read_text())
                run.update(configuration=a.configuration, load_average=list(os.getloadavg()), recorded=not a.unrecorded, completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), app=str(a.app), git=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),template=a.template,
                           machine=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip())
                (result/'scroll-result.json').write_text(json.dumps(run,indent=2))
                if recorder is not None:
                    remember_staging(recorder)
                    recorder.send_signal(__import__('signal').SIGINT)
                    deadline=time.monotonic()+600
                    while recorder.poll() is None:
                        # The kernel stream may be handed to the recorder only during deferred
                        # processing. Capture descriptor ownership then, as well as during recording.
                        remember_staging(recorder)
                        if time.monotonic() > deadline: raise TimeoutError('xctrace deferred processing exceeded 600 seconds')
                        time.sleep(5)
                    if recorder.returncode: raise RuntimeError('xctrace failed to save')
            if not a.unrecorded:
                subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--toc','--output',str(result/'toc.xml')],check=True)
                subprocess.run(['python3',str(root/'scripts/scroll-trace-summary.py'),str(result)],check=True)
            print(json.dumps(run,indent=2),flush=True)
            if not run['completed']: print('INCOMPLETE TRAVERSAL: trace retained; gate cannot pass.',flush=True)
            shutil.rmtree(recorder_temporary)
            print('Artifacts:',result,flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
        for path, inode in owned_staging.items():
            try:
                if path.stat().st_ino == inode: path.unlink()
            except FileNotFoundError: pass
        shutil.rmtree(recorder_temporary, ignore_errors=True)
