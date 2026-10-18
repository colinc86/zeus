#!/usr/bin/env bash
# CPU-time deltas (30 s by default), idle wakeups/s and energy impact for the built app. Isolated state and optional idle bridge.
# Default: visible Zeus, closed conversation, no cards. --pid attaches read-only.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$PWD" "$@" <<'PY'
import argparse, csv, datetime, json, os, pathlib, plistlib, shutil, statistics, subprocess, sys, tempfile, time

root = pathlib.Path(sys.argv[1])
p = argparse.ArgumentParser(description='Measure one-core CPU usage for 30 s; builds are separate. Existing PIDs are never terminated.')
p.add_argument('--app', type=pathlib.Path, default=root / 'build/DerivedData/Build/Products/Debug/Zeus.app')
p.add_argument('--pid', type=int, help='read-only measurement of an existing app or bridge')
p.add_argument('--output', type=pathlib.Path, default=root / 'build/tmp/perf2', help='task-owned result directory')
p.add_argument('--max-cpu', type=float, help='fail if mean one-core CPU percent exceeds this bound')
p.add_argument('--max-idle-wakeups', type=float, help='fail if package-idle wakeups/s exceeds this bound')
p.add_argument('--max-wakeups', type=float, help='fail if interrupt wakeups/s exceeds this bound')
p.add_argument('--managed', action='store_true', help='production managed polling of a synthetic idle CLI on a private socket')
p.add_argument('--frames', action='store_true', help='separate animation proof; enables a diagnostic 1 Hz counter')
p.add_argument('--hidden', action='store_true', help='launch with the avatar hidden')
p.add_argument('--character', default='zeus')
p.add_argument('--history', type=int, default=0, help='seed N seen, dismissed synthetic cards in isolated history')
p.add_argument('--bridge', action='store_true', help='also launch an idle real bundled bridge')
p.add_argument('--trace', action='store_true', help='record a separate 10 s Time Profiler trace after CPU measurement')
p.add_argument('--sample', action='store_true', help='collect a separate 10 s stack sample after CPU measurement')
p.add_argument('--label', default='idle')
p.add_argument('--seconds', type=int, default=30, help='length of the CPU interval')
p.add_argument('--learn', action='store_true', help='turn on Learn from me (recorder and idle poll) in the isolated home')
p.add_argument('--ghost', type=float, help='turn on Fade Zeus when idle at this opacity, after the shortest delay (5 s)')
p.add_argument('--question', action='store_true', help='also seed one open, seen question card')
a = p.parse_args(sys.argv[2:])
if a.learn: p.error('--learn is disabled: production recording must not inspect the user workspace in a performance fixture')
if a.history < 0: p.error('--history must be nonnegative')
if a.seconds < 5: p.error('--seconds must be at least 5')
if a.pid and (a.hidden or a.bridge or a.history or a.learn or a.ghost is not None or a.question or a.managed):
    p.error('--hidden/--bridge/--history/--learn/--ghost/--question require an isolated launch')
label = ''.join(c if c.isalnum() or c in '-_' else '_' for c in a.label)
result = a.output / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + label)
result.mkdir(parents=True)
children, handles = [], []

# ps TIME is cumulative user+system CPU, unlike its rolling %CPU column.
def cpu_seconds(text):
    days = 0
    if '-' in text: day, text = text.split('-', 1); days = int(day)
    parts = list(map(float, text.split(':')))
    return days * 86400 + sum(value * 60 ** i for i, value in enumerate(reversed(parts)))
assert cpu_seconds('1-00:00:01.20') == 86401.2
assert cpu_seconds('2:03.50') == 123.5

def counters(targets):
    out = subprocess.check_output(['/bin/ps', '-p', ','.join(map(str, targets.values())), '-o', 'pid=,time=,rss='], text=True)
    rows = {int(v[0]): (cpu_seconds(v[1]), int(v[2])) for line in out.splitlines() if len(v := line.split()) == 3}
    if set(rows) != set(targets.values()): raise RuntimeError('A measured process exited during the CPU interval')
    return rows

# Wakeups come from proc_pid_rusage (top's IDLEW column reads 0 for these processes): interrupt wakeups, and the
# package-idle wakeups Activity Monitor calls "Idle Wake Ups".
import ctypes
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
class RUsage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('user_time', ctypes.c_uint64), ('system_time', ctypes.c_uint64),
                ('pkg_idle_wkups', ctypes.c_uint64), ('interrupt_wkups', ctypes.c_uint64), ('rest', ctypes.c_uint64 * 40)]
def wakeups(pid):
    usage = RUsage()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0: return None
    return usage.interrupt_wkups, usage.pkg_idle_wkups

temporary_home = tempfile.TemporaryDirectory(prefix='zperf_', dir='/private/tmp')
try:
    home = pathlib.Path(temporary_home.name)
    if a.pid:
        targets = {'attached': a.pid}
        command = subprocess.check_output(['/bin/ps', '-p', str(a.pid), '-o', 'command='], text=True).strip()
        context = {'mode': 'attached; retain current app state', 'command': command}
    else:
        app = a.app.resolve()
        with (app / 'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
        executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
        probe_binaries = [executable, executable.with_name(executable.name + '.debug.dylib')]
        if not any(path.is_file() and b'ZEUS_PERF_ISOLATED_READY' in path.read_bytes() for path in probe_binaries):
            raise RuntimeError('Build a Debug app with isolated performance dependencies before profiling')
        prefs = home / 'Library/Preferences'; prefs.mkdir(parents=True)
        settings = {'general.welcomeShown': True, 'avatar.manuallyHidden': a.hidden,
                    'character.id': a.character, 'quiet.enabled': False,
                    'general.sound': False, 'general.typewriter': False,
                    'general.talkHotKey': json.dumps({'key': 'Z', 'command': True, 'option': True,
                        'control': False, 'shift': False, 'enabled': False}).encode()}
        if a.learn: settings.update({'learn.enabled': True, 'learn.introShown': True})
        if a.ghost is not None: settings.update({'avatar.ghost.enabled': True, 'avatar.ghost.opacity': a.ghost, 'avatar.ghost.delay': 5.0})
        with (prefs / (info['CFBundleIdentifier'] + '.plist')).open('wb') as f: plistlib.dump(settings, f)
        if a.history or a.question:
            support = home / 'Library/Application Support/Zeus'; support.mkdir(parents=True)
            cards = [{'id': 'c_%08d' % i, 'kind': 'message', 'body': 'A completed update from the assistant.',
                      'options': [], 'attachments': [], 'priority': 'normal',
                      'createdAt': '2026-10-10T00:00:00Z', 'updatedAt': '2026-10-10T00:00:00Z',
                      'status': 'dismissed'} for i in range(a.history)]
            if a.question:
                cards.append({'id': 'c_question', 'kind': 'question', 'title': 'Slides', 'body': 'Update last deck, or start fresh?',
                              'options': [{'id': 'u', 'label': 'Update', 'style': 'primary'}, {'id': 'f', 'label': 'Start fresh', 'style': 'secondary'}],
                              'attachments': [], 'priority': 'normal', 'createdAt': '2026-10-10T00:01:00Z',
                              'updatedAt': '2026-10-10T00:01:00Z', 'status': 'open'})
            (support / 'cards.json').write_text(json.dumps({'version': 1, 'cards': cards, 'seenIDs': [c['id'] for c in cards]}))
        # Never start a managed agent, and keep any tmux use off the user's server and agent configs.
        tmux_dir = home / 'tmux'; tmux_dir.mkdir()
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR') or k.startswith('ZEUS_PERF_')}
        env.update(CFFIXED_USER_HOME=str(home), HOME=str(home), TMUX_TMPDIR=str(tmux_dir), ZEUS_PERF_PROBE='1', ZEUS_PERF_DIAGNOSTICS='1')
        if a.managed:
            (home / 'project').mkdir()
            fixture = home / 'idle-claude'
            fixture.write_text("#!/usr/bin/python3\nimport os, sys, time\nif '--help' in sys.argv: print('Private fixture --system-prompt-snapshot'); sys.exit(0)\nprint('───\\n❯\u00a0\\n───\\x1b[1A\\r\\x1b[2C', end='', flush=True)\nwhile True:\n try: os.kill(" + str(os.getpid()) + ", 0)\n except ProcessLookupError: break\n time.sleep(1)\n")
            fixture.chmod(0o700)
            env['ZEUS_PERF_MANAGED'] = '1'
        env.pop('TMUX', None)
        if a.frames: env['ZEUS_FRAME_COUNTER'] = '1'
        managed_off = json.dumps({'enabled': False, 'folder': '', 'agent': 'claude',
                                  'launchPrompt': '', 'startWhenZeusOpens': False}).encode()
        # Launch normally; test-host markers would silently suppress runtime/UI startup.
        env.pop('XCTestConfigurationFilePath', None)
        log = (result / 'app.log').open('wb'); handles.append(log)
        child = subprocess.Popen([str(executable), '-general.welcomeShown', 'YES',
            '-avatar.manuallyHidden', 'YES' if a.hidden else 'NO', '-character.id', a.character,
            '-agent.managedSession', '<' + managed_off.hex() + '>'],
            env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        children.append(child); targets = {'app': child.pid}
        socket = home / 'Library/Application Support/Zeus/bridge.sock'
        deadline = time.monotonic() + 10
        while not socket.exists():
            if child.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Isolated app did not start a healthy runtime; inspect app.log')
            time.sleep(0.1)
        context = {'mode': 'isolated launch', 'app': str(app), 'character': a.character, 'hidden': a.hidden,
                   'conversation': os.environ.get('ZEUS_PERF_PANEL') or 'closed', 'cards': a.history, 'bridge': a.bridge,
                   'learn': a.learn, 'managed_synthetic': a.managed, 'ghost_opacity': a.ghost, 'question': a.question,
                   'activity': os.environ.get('ZEUS_PERF_ACTIVITY'), 'ignore_occlusion': os.environ.get('ZEUS_PERF_IGNORE_OCCLUSION') == '1'}
        if a.bridge:
            output = (result / 'bridge.stdout.ndjson').open('wb'); error = (result / 'bridge.stderr').open('wb')
            handles.extend([output, error])
            bridge = subprocess.Popen([str(app / 'Contents/MacOS/zeus-mcp'), '--agent', 'claude', '--socket', str(socket)],
                stdin=subprocess.PIPE, stdout=output, stderr=error, env=env, cwd=home)
            children.append(bridge); targets['bridge'] = bridge.pid
            for msg in [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
                'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'Zeus perf', 'version': '1'}}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'}]:
                bridge.stdin.write((json.dumps(msg) + '\n').encode())
            bridge.stdin.flush()
    time.sleep(20 if a.managed else 5) # exclude startup, managed readiness grace, font registration and first render
    if not a.pid:
        history = home / 'Library/Application Support/Zeus/cards.json'
        actual = json.loads(history.read_text()) if history.exists() else {'cards': []}
        if len(actual['cards']) != a.history + (1 if a.question else 0):
            raise RuntimeError('Unexpected cards/welcome: isolated launch controls did not take effect')
    # top's second sample covers the same interval: that interval's energy impact (POWER).
    tops = {name: subprocess.Popen(['/usr/bin/top', '-l', '2', '-s', str(a.seconds), '-pid', str(pid), '-stats', 'pid,power'],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True) for name, pid in targets.items()}
    wake_start = {name: wakeups(pid) for name, pid in targets.items()}
    start_values = previous = counters(targets); start = prior_time = time.monotonic()
    rows = []; per_target = {name: [] for name in targets}
    for n in range(1, a.seconds + 1):
        time.sleep(max(0, start + n - time.monotonic()))
        current = counters(targets); now = time.monotonic()
        for name, pid in targets.items():
            cpu = (current[pid][0] - previous[pid][0]) / (now - prior_time) * 100
            per_target[name].append(cpu)
            rows.append([name, pid, now - start, current[pid][0], cpu, current[pid][1]])
        previous, prior_time = current, now
    elapsed = now - start
    wake_end = {name: wakeups(pid) for name, pid in targets.items()}
    summary = {'context': context, 'git': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
               'os': subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).strip(),
               'machine': subprocess.check_output(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
               'measurement': '100% = one full CPU core; cumulative ps TIME delta / monotonic elapsed',
               'elapsed_seconds': elapsed, 'processes': {}}
    def top_figures(name, pid):
        figures = {}
        if wake_start[name] and wake_end[name]:
            figures['wakeups_per_second'] = (wake_end[name][0] - wake_start[name][0]) / elapsed
            figures['idle_wakeups_per_second'] = (wake_end[name][1] - wake_start[name][1]) / elapsed
        out, _ = tops[name].communicate(timeout=a.seconds + 30)
        samples = [line.split() for line in out.splitlines() if line.split()[:1] == [str(pid)]]
        if len(samples) >= 2: figures['energy_impact'] = float(samples[1][1])
        return figures
    for name, pid in targets.items():
        summary['processes'][name] = {**top_figures(name, pid), 'pid': pid, 'cpu_seconds': previous[pid][0] - start_values[pid][0],
            'mean_cpu_percent': (previous[pid][0] - start_values[pid][0]) / elapsed * 100,
            'median_one_second_percent': statistics.median(per_target[name]),
            'max_one_second_percent': max(per_target[name]), 'rss_kib': previous[pid][1]}
    with (result / 'cpu.csv').open('w') as f:
        writer = csv.writer(f); writer.writerow(['process', 'pid', 'elapsed_s', 'cpu_time_s', 'interval_cpu_percent', 'rss_kib']); writer.writerows(rows)
    if a.frames and not a.pid:
        frames = [json.loads(line.removeprefix('ZEUS_FRAMES: ')) for line in (result / 'app.log').read_text().splitlines() if line.startswith('ZEUS_FRAMES: ')]
        summary['animation_samples'] = frames
        if not frames: raise RuntimeError('Frame diagnostics missing; do not interpret idle CPU as live animation proof')
        if not a.hidden:
            views = [view for frame in frames for view in frame['views'] if view['surface'] == 'Zeus avatar']
            if len(views) < 2 or views[-1]['pixelChanges'] <= views[0]['pixelChanges'] or not all(view['layerMatchesDriver'] for view in views):
                raise RuntimeError('Visible avatar did not prove changing native pixels')
    (result / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)
    print('Artifacts:', result, flush=True)
    violations = []
    for name, values in summary['processes'].items():
        for field, bound in [('mean_cpu_percent', a.max_cpu), ('idle_wakeups_per_second', a.max_idle_wakeups), ('wakeups_per_second', a.max_wakeups)]:
            if bound is not None and (values.get(field) is None or values[field] > bound):
                violations.append(f'{name}: {field}={values.get(field)} exceeds {bound}')
    if violations: raise RuntimeError('; '.join(violations))
    if a.trace:
        for name, pid in targets.items():
            subprocess.run(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--attach', str(pid),
                            '--time-limit', '10s', '--output', str(result / (name + '.trace')), '--no-prompt'], check=True, timeout=45)
    if a.sample:
        for name, pid in targets.items():
            subprocess.run(['/usr/bin/sample', str(pid), '10', '1', '-file', str(result / (name + '.sample.txt'))], check=True, timeout=30)
finally:
    for child in reversed(children):
        if child.stdin:
            try: child.stdin.close()
            except OSError: pass
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
    if a.managed and not a.pid and (home / 'tmux.sock').exists():
        tmux = shutil.which('tmux')
        if tmux: subprocess.run([tmux, '-S', str(home / 'tmux.sock'), 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    for handle in handles: handle.close()
    temporary_home.cleanup()
PY
