"""Repeated, interleaved scroll captures. Each configuration reports medians and full ranges."""
import argparse, datetime, hashlib, json, pathlib, random, shutil, statistics, subprocess, sys

CONFIGURATIONS = ['baseline', 'opaque-panel', 'single-frame', 'avatar-paused', 'sf-mono', 'local-events']

def capture_valid(summary):
    return summary['completed'] and summary['surface_valid'] and summary['traversal_valid'] \
        and summary.get('input_valid',True) and summary['target_updates'] > 0

def aggregate(records, configurations, requested):
    result = {}
    for configuration in configurations:
        rows = [r for r in records if r['configuration'] == configuration]
        valid = [r for r in rows if capture_valid(r['summary'])]
        def metric(key):
            values = [r['summary'][key] for r in valid]
            return dict(median=statistics.median(values), minimum=min(values), maximum=max(values), values=values) if values else None
        result[configuration] = dict(requested=requested, captures=len(rows), valid=len(valid),
            hitch_ms_per_s=metric('hitch_ms_per_s'), worst_hitch_ms=metric('worst_hitch_ms'),
            gate_passes=sum(r['summary']['gate_pass'] for r in valid),
            all_pass=len(valid) == requested and all(r['summary']['gate_pass'] for r in valid))
    return result

def plan(configurations, captures, seed):
    rng = random.Random(seed)
    result = []
    for round_number in range(1, captures + 1):
        order = list(configurations); rng.shuffle(order)
        result.extend(dict(round=round_number, configuration=c) for c in order)
    return result

def report(directory, metadata):
    summary = aggregate(metadata['records'], metadata['configurations'], metadata['captures'])
    (directory/'batch-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print('Configuration | Valid N | Hitch ms/s median [min, max] | Worst ms median [min, max] | Gates passed', flush=True)
    for name, row in summary.items():
        def fmt(key):
            v=row[key]
            return f"{v['median']:.3f} [{v['minimum']:.3f}, {v['maximum']:.3f}]" if v else 'unavailable'
        print(f"{name} | {row['valid']}/{row['requested']} | {fmt('hitch_ms_per_s')} | {fmt('worst_hitch_ms')} | {row['gate_passes']}/{row['requested']}", flush=True)
    return summary

def main():
    root = pathlib.Path(sys.argv[1]).resolve()
    parser = argparse.ArgumentParser()
    parser.add_argument('--label', default='comparison')
    parser.add_argument('--captures', type=int, default=5)
    parser.add_argument('--configuration', choices=CONFIGURATIONS, default='baseline')
    parser.add_argument('--matrix', action='store_true', help='interleave every configuration in each round')
    parser.add_argument('--seed', type=int, default=13)
    parser.add_argument('--retain-traces', choices=['first', 'all'], default='first', help='exports and summaries always remain')
    parser.add_argument('--template', default='Animation Hitches')
    parser.add_argument('--app', type=pathlib.Path, default=root/'build/ReleasePerf/Build/Products/Release/Zeus.app')
    parser.add_argument('--resume', type=pathlib.Path)
    args = parser.parse_args(sys.argv[2:])
    if args.captures < 1: parser.error('--captures must be positive')
    app = args.app.resolve()
    if not app.is_relative_to(root/'build'): parser.error('--app must be inside this worktree’s build/')
    import plistlib
    with (app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
    executable=app/'Contents/MacOS'/info['CFBundleExecutable']
    fingerprint=hashlib.sha256(executable.read_bytes()).hexdigest()
    if args.resume:
        directory=args.resume.resolve()
        if not directory.is_relative_to(root/'build'): parser.error('--resume must be inside this worktree’s build/')
        metadata=json.loads((directory/'batch.json').read_text())
        if metadata['app_sha256'] != fingerprint: parser.error('the app changed; create a new batch')
    else:
        label=''.join(c if c.isalnum() or c in '-_' else '_' for c in args.label)
        directory=root/'build/scroll-perf'/('batch-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+label)
        directory.mkdir(parents=True)
        configurations=CONFIGURATIONS if args.matrix else [args.configuration]
        metadata=dict(app=str(app), app_sha256=fingerprint, captures=args.captures, configurations=configurations,
            seed=args.seed, template=args.template, retain_traces=args.retain_traces, plan=plan(configurations,args.captures,args.seed),
            records=[], git=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    print('Batch:',directory,flush=True)
    (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')
    if 'local-events' in metadata['configurations'] and not metadata.get('input_preflight_done'):
        artifact=directory/'input-preflight'
        if artifact.exists(): artifact.rename(artifact.with_name('input-preflight-incomplete-'+datetime.datetime.now().strftime('%H%M%S')))
        print('Validate window-local phased input (unrecorded; excluded from statistics)',flush=True)
        with (directory/'input-preflight.log').open('w') as log:
            run=subprocess.run([sys.executable,str(root/'scripts/scroll-capture.py'),str(root),'--unrecorded',
                '--configuration','local-events','--app',metadata['app'],'--output',str(artifact)],stdout=log,stderr=log)
        if run.returncode:
            metadata['failure']=dict(stage='input-preflight',artifact=str(artifact),returncode=run.returncode)
            (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')
            report(directory,metadata)
            raise RuntimeError('Input preflight unavailable; inspect readiness.json / input-preflight.log before resuming')
        pilot=json.loads((artifact/'scroll-result.json').read_text())
        supported=pilot['completed'] and pilot['wheel_events'] > 0 and 'interacting' in pilot['scroll_phases']
        metadata['input_preflight_done']=True
        metadata['input_preflight_result']=pilot
        if not supported:
            metadata['excluded_configurations']={'local-events':'Window-local phased input did not traverse the fixture; no global-event fallback'}
            metadata['configurations'].remove('local-events')
            metadata['plan']=plan(metadata['configurations'],metadata['captures'],metadata['seed'])
            print('Optional local-events comparison excluded: input did not traverse the fixture.',flush=True)
        metadata.pop('failure',None)
        (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')

    for index, item in enumerate(metadata['plan']):
        if any(r['index'] == index for r in metadata['records']): continue
        artifact=directory/f"{index+1:02}-r{item['round']}-{item['configuration']}"
        if artifact.exists():
            artifact.rename(artifact.with_name(artifact.name+'-incomplete-'+datetime.datetime.now().strftime('%H%M%S')))
        (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')
        print(f"Capture {index+1}/{len(metadata['plan'])}: round {item['round']} {item['configuration']}",flush=True)
        with (directory/f'{index+1:02}-capture.log').open('w') as log:
            run=subprocess.run([sys.executable, str(root/'scripts/scroll-capture.py'), str(root), '--configuration',item['configuration'],
                '--app',metadata['app'], '--template',metadata['template'], '--output',str(artifact)],stdout=log,stderr=log)
        if run.returncode:
            metadata['failure']=dict(index=index,returncode=run.returncode,artifact=str(artifact))
            (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')
            report(directory, metadata)
            raise RuntimeError(f'Capture failed; inspect {directory}/{index+1:02}-capture.log; resume only after resolving the cause')
        summary=json.loads((artifact/'hitch-summary.json').read_text())
        if not capture_valid(summary):
            metadata.setdefault('invalid_attempts',[]).append(dict(index=index, **item, artifact=str(artifact), summary=summary))
            metadata['failure']=dict(index=index, reason='Invalid rendered traversal', artifact=str(artifact))
            (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')
            report(directory,metadata)
            raise RuntimeError('Invalid capture excluded; resolve visibility/input/traversal before resuming')
        retained=metadata['retain_traces'] == 'all' or not any(r['configuration']==item['configuration'] for r in metadata['records'])
        metadata['records'].append(dict(index=index, **item, artifact=str(artifact), summary=summary, trace_retained=retained))
        metadata.pop('failure',None)
        (directory/'batch.json').write_text(json.dumps(metadata,indent=2)+'\n')
        if not retained: shutil.rmtree(artifact/'scroll.trace')
        report(directory, metadata)
    print('Complete:',directory,flush=True)

if __name__ == '__main__': main()
