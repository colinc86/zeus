#!/usr/bin/env python3
"""Serial real-agent release gate; evidence is private under build/live/<timestamp>.

--quick is smoke coverage, not the full release gate. See docs/RELEASE.md.
"""
import argparse
import datetime
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Zeus/App/Tests/Runtime'))
from LiveSupport import cleanup_root, scrub_paths

AGENTS = ('claude', 'codex', 'opencode')
PROBES = {'ac1': ('claude',), 'lv1': ('claude',), 'sa1': ('claude',),
          'sa2': ('codex', 'opencode'), 'sa3': AGENTS, 'sa4': AGENTS, 'pc1': AGENTS, 'cy1': AGENTS, 'e2e': ('—',)}
SCRIPTS = {'ac1': 'Zeus/App/Tests/Runtime/AC1LiveProbe.py', 'lv1': 'Zeus/App/Tests/Runtime/AC1LiveProbe.py',
           'sa1': 'Zeus/App/Tests/SA1LiveProbe.py',
           **{p: f'Zeus/App/Tests/Runtime/{p.upper()}LiveProbe.py' for p in ('sa2','sa3','sa4')},
           'pc1': 'Zeus/App/Tests/Runtime/PC1LiveScreens.py'}
TIMEOUTS = {'ac1': 360, 'lv1': 600, 'sa1': 600, 'sa2': 420, 'sa3': 420, 'sa4': 360, 'pc1': 480, 'cy1': 360, 'e2e': 420}


def comma_values(value, allowed):
    values = tuple(dict.fromkeys(value.lower().split(',')))
    if not values or any(v not in allowed for v in values):
        raise argparse.ArgumentTypeError('Choose comma-separated values from: ' + ','.join(allowed))
    return values


def plan(agents, probes, available):
    return [(p,a, 'run' if a == '—' or a in available else 'skip')
            for p in probes for a in PROBES[p] if a == '—' or a in agents]


def xcode_command(probe, output):
    suite = 'ConnectOwnLiveTests' if probe == 'cy1' else 'ZeusE2ETests'
    return ['xcodebuild','-project','Zeus.xcodeproj','-scheme','Zeus','-configuration','Debug',
            '-destination','platform=macOS,arch='+os.uname().machine,
            '-derivedDataPath',str(ROOT/'build/DerivedData'),
            '-clonedSourcePackagesDirPath',str(ROOT/'build/SourcePackages'),
            '-resultBundlePath',str(output/'result.xcresult'), '-only-testing:ZeusTests/'+suite,'test-without-building','-quiet']


def command(probe, agent, output, quick, record):
    if probe in ('cy1','e2e'):return xcode_command(probe,output)
    argv = [sys.executable,'-B',SCRIPTS[probe]]
    if probe in ('ac1','lv1'):argv += ['--scenario',probe]
    if probe in ('sa2','sa3','sa4','pc1'):argv += ['--agent',agent]
    if quick:argv += ['--quick']
    if record and probe != 'ac1':
        argv += ['--record-fixtures' if probe in ('lv1','sa1') else '--record']
        if probe == 'pc1' and agent == 'claude':argv += ['--native-updater']
    return argv


def run_bounded(argv, env, output, timeout):
    """No retries. SIGTERM permits fixture finally blocks; SIGKILL is a bounded fallback."""
    with (output/'console.log').open('w') as log:
        process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=timeout)
            return 'PASS' if process.returncode == 0 else 'FAIL', process.returncode
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGTERM)
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
            return 'TIMEOUT', None
        except BaseException:
            os.killpg(process.pid,signal.SIGTERM)
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
            raise


def sweep(registry):
    # Only namespaces explicitly registered by this gate's children are ever cleaned.
    if registry.exists():
        for line in registry.read_text().splitlines():cleanup_root(json.loads(line))


def scrub_evidence(output, registry):
    replacements={str(ROOT):'/WORKTREE'}
    if registry.exists():replacements.update({json.loads(v):'/FIXTURE' for v in registry.read_text().splitlines()})
    for agent in AGENTS:
        if cli:=shutil.which(agent):replacements[cli]='/CLI/'+agent
    for file in output.rglob('*'):
        if file.is_file() and file.suffix in ('.json','.jsonl','.ndjson','.txt','.log','.ansi') and file != registry:
            value=file.read_text(errors='replace');file.write_text(scrub_paths(value,replacements))


def xcode_summary(output):
    result=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(output/'result.xcresult')],capture_output=True,text=True,timeout=30)
    result.check_returncode();summary=json.loads(result.stdout)
    (output/'proof.json').write_text(json.dumps(summary,indent=2)+'\n')
    return summary['result']=='Passed' and summary['failedTests']==0 and summary['passedTests']>0 and summary['skippedTests']==0


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agents',type=lambda v:comma_values(v,AGENTS),default=AGENTS)
    parser.add_argument('--only',type=lambda v:comma_values(v,PROBES),default=tuple(PROBES),help='Probe IDs: '+','.join(PROBES))
    parser.add_argument('--quick',action='store_true',help='Shortest scenario per probe; full default is the release gate')
    parser.add_argument('--record',action='store_true',help='Explicitly update scrubbed fixtures using each probe recording option')
    args=parser.parse_args(argv)
    if args.record and args.quick:parser.error('--record requires full scenarios (omit --quick)')
    began=time.monotonic()
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    run=ROOT/'build/live'/stamp;run.mkdir(parents=True)
    rows=[];failed=False
    available={a for a in args.agents if shutil.which(a)}
    jobs=plan(args.agents,args.only,available)
    if not jobs:parser.error('No selected probe applies to the selected agents')
    print('Live gate:',run.relative_to(ROOT), '(quick)' if args.quick else '(full)',flush=True)
    # Do not inherit opt-in fixture recording or other test runner live switches.
    base={k:v for k,v in os.environ.items() if not k.startswith(('ZEUS_LIVE_','ZEUS_CY1_','TEST_RUNNER_ZEUS_'))}
    build=run/'build';build.mkdir()
    if not shutil.which('tmux'):
        print('FAIL: tmux is required for isolated live checks.',flush=True)
        result='FAIL';(build/'console.log').write_text('tmux is required for private live fixtures.\n')
    else:
        app_build=build/'app';app_build.mkdir()
        result,_=run_bounded(['scripts/build.sh'],base,app_build,600)
    if result=='PASS' and any(p in ('cy1','e2e') and action=='run' for p,a,action in jobs):
        # Prepare the native test bundle once; each row thereafter only executes it.
        argv=xcode_command('e2e',build)
        argv=argv[:argv.index('-resultBundlePath')]+['build-for-testing','-quiet']
        test_build=build/'native-tests';test_build.mkdir()
        result,_=run_bounded(argv,base,test_build,600)
    if result!='PASS':
        rows.append(dict(probe='build',agent='—',result=result,seconds=round(time.monotonic()-began,2),evidence=str(build.relative_to(ROOT))))
        failed=True
    else:
        for probe,agent,action in jobs:
            if action=='skip':
                print(f'SKIP {probe}/{agent}: {agent} CLI is not installed.',flush=True)
                rows.append(dict(probe=probe,agent=agent,result='SKIP',seconds=0,evidence='CLI not installed'));continue
            output=run/probe/agent;output.mkdir(parents=True)
            registry=output/'namespaces.private';env=dict(base,ZEUS_LIVE_OUTPUT=str(output),ZEUS_LIVE_REGISTRY=str(registry))
            if probe=='cy1':
                for key,value in {'ZEUS_CY1_LIVE':'1','ZEUS_CY1_AGENTS':agent,'ZEUS_CY1_EVIDENCE_DIR':str(output),'ZEUS_CY1_RECORD_FIXTURES':'1' if args.record else '0',
                                  'ZEUS_LIVE_REGISTRY':str(registry),'ZEUS_LIVE_OUTPUT':str(output)}.items():
                    env[key]=value;env['TEST_RUNNER_'+key]=value
            if probe=='e2e':env['TEST_RUNNER_ZEUS_TEST_TMUX']='1';env['ZEUS_TEST_TMUX']='1'
            start=time.monotonic();print(f'RUN {probe}/{agent} (timeout {TIMEOUTS[probe]}s)',flush=True)
            try:
                result,code=run_bounded(command(probe,agent,output,args.quick,args.record),env,output,TIMEOUTS[probe])
                if result=='PASS' and probe in ('cy1','e2e') and not xcode_summary(output):result='FAIL'
                if result=='PASS' and probe=='sa1':
                    proof=json.loads((output/'proof.json').read_text())
                    if not proof.get('scenarios') or any(not v['within_5s'] for v in proof['scenarios']):result='FAIL'
            except Exception as error:
                result='FAIL';code=None;(output/'gate-error.txt').write_text(str(error))
            finally:
                try:sweep(registry)
                except Exception as error:
                    result='FAIL';(output/'cleanup-error.txt').write_text(str(error))
                scrub_evidence(output,registry)
            row=dict(probe=probe,agent=agent,result=result,seconds=round(time.monotonic()-start,2),evidence=str(output.relative_to(ROOT)))
            rows.append(row);failed|=result!='PASS'
            (output/'gate.json').write_text(json.dumps(dict(row,exit_code=code),indent=2)+'\n')
            print(f'{result} {probe}/{agent} ({row["seconds"]:.2f}s)',flush=True)
    elapsed=round(time.monotonic()-began,2)
    manifest=dict(revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),quick=args.quick,record=args.record,agents=args.agents,rows=rows,seconds=elapsed,result='FAIL' if failed else 'PASS')
    (run/'summary.json').write_text(json.dumps(manifest,indent=2)+'\n')
    table=['| Probe | Agent | Result | Seconds | Evidence |','|---|---|---|---:|---|']
    table += [f'| {r["probe"]} | {r["agent"]} | {r["result"]} | {r["seconds"]:.2f} | {r["evidence"]} |' for r in rows]
    table += [f'\nTotal wall time: {elapsed:.2f}s. Result: {manifest["result"]}.']
    (run/'summary.md').write_text('\n'.join(table)+'\n');print('\n'.join(table),flush=True)
    return int(failed)


if __name__=='__main__':raise SystemExit(main())
