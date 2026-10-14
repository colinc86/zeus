#!/usr/bin/env bash
# 30-second CPU-time deltas for the built app. Isolated state and optional idle bridge.
# Default: visible Zeus, closed conversation, no cards. --pid attaches read-only.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$PWD" "$@" <<'PY'
import argparse, csv, datetime, json, os, pathlib, plistlib, statistics, subprocess, sys, tempfile, time

root = pathlib.Path(sys.argv[1])
p = argparse.ArgumentParser(description='Measure one-core CPU usage for 30 s; builds are separate. Existing PIDs are never terminated.')
p.add_argument('--app', type=pathlib.Path, default=root / 'build/DerivedData/Build/Products/Debug/Zeus.app')
p.add_argument('--pid', type=int, help='read-only measurement of an existing app or bridge')
p.add_argument('--hidden', action='store_true', help='launch with the avatar hidden')
p.add_argument('--character', default='zeus')
p.add_argument('--history', type=int, default=0, help='seed N seen, dismissed synthetic cards in isolated history')
p.add_argument('--bridge', action='store_true', help='also launch an idle real bundled bridge')
p.add_argument('--trace', action='store_true', help='record a separate 10 s Time Profiler trace after CPU measurement')
p.add_argument('--sample', action='store_true', help='collect a separate 10 s stack sample after CPU measurement')
p.add_argument('--label', default='idle')
a = p.parse_args(sys.argv[2:])
if a.history < 0: p.error('--history must be nonnegative')
if a.pid and (a.hidden or a.bridge or a.history): p.error('--hidden/--bridge require an isolated launch')
label = ''.join(c if c.isalnum() or c in '-_' else '_' for c in a.label)
result = root / 'build/perf' / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + label)
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
        prefs = home / 'Library/Preferences'; prefs.mkdir(parents=True)
        settings = {'general.welcomeShown': True, 'avatar.manuallyHidden': a.hidden,
                    'character.id': a.character, 'quiet.enabled': False,
                    'general.sound': False, 'general.typewriter': False,
                    'general.talkHotKey': json.dumps({'key': 'Z', 'command': True, 'option': True,
                        'control': False, 'shift': False, 'enabled': False}).encode()}
        with (prefs / (info['CFBundleIdentifier'] + '.plist')).open('wb') as f: plistlib.dump(settings, f)
        if a.history:
            support = home / 'Library/Application Support/Zeus'; support.mkdir(parents=True)
            cards = [{'id': 'c_%08d' % i, 'kind': 'message', 'body': 'A completed update from the assistant.',
                      'options': [], 'attachments': [], 'priority': 'normal',
                      'createdAt': '2026-10-10T00:00:00Z', 'updatedAt': '2026-10-10T00:00:00Z',
                      'status': 'dismissed'} for i in range(a.history)]
            (support / 'cards.json').write_text(json.dumps({'version': 1, 'cards': cards, 'seenIDs': [c['id'] for c in cards]}))
        # Never start a managed agent, and keep any tmux use off the user's server and agent configs.
        tmux_dir = home / 'tmux'; tmux_dir.mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), HOME=str(home), TMUX_TMPDIR=str(tmux_dir))
        env.pop('TMUX', None)
        managed_off = json.dumps({'enabled': False, 'folder': '', 'agent': 'claude',
                                  'launchPrompt': '', 'startWhenZeusOpens': False}).encode()
        # Launch normally; test-host markers would silently suppress runtime/UI startup.
        env.pop('XCTestConfigurationFilePath', None)
        log = (result / 'app.log').open('wb'); handles.append(log)
        child = subprocess.Popen([str(executable), '-general.welcomeShown', 'YES',
            '-avatar.manuallyHidden', 'YES' if a.hidden else 'NO', '-character.id', a.character,
            '-agent.managedSession', '<' + managed_off.hex() + '>'],
            env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        children.append(child); targets = {'app': child.pid}
        socket = home / 'Library/Application Support/Zeus/bridge.sock'
        deadline = time.monotonic() + 10
        while not socket.exists():
            if child.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Isolated app did not start a healthy runtime; inspect app.log')
            time.sleep(0.1)
        context = {'mode': 'isolated launch', 'app': str(app), 'character': a.character,
                   'hidden': a.hidden, 'conversation': 'closed', 'cards': a.history, 'bridge': a.bridge}
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
    time.sleep(5) # exclude startup, font registration and first render
    if not a.pid:
        history = home / 'Library/Application Support/Zeus/cards.json'
        actual = json.loads(history.read_text()) if history.exists() else {'cards': []}
        if len(actual['cards']) != a.history:
            raise RuntimeError('Unexpected cards/welcome: isolated launch controls did not take effect')
    start_values = previous = counters(targets); start = prior_time = time.monotonic()
    rows = []; per_target = {name: [] for name in targets}
    for n in range(1, 31):
        time.sleep(max(0, start + n - time.monotonic()))
        current = counters(targets); now = time.monotonic()
        for name, pid in targets.items():
            cpu = (current[pid][0] - previous[pid][0]) / (now - prior_time) * 100
            per_target[name].append(cpu)
            rows.append([name, pid, now - start, current[pid][0], cpu, current[pid][1]])
        previous, prior_time = current, now
    elapsed = now - start
    summary = {'context': context, 'git': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
               'os': subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).strip(),
               'machine': subprocess.check_output(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
               'measurement': '100% = one full CPU core; cumulative ps TIME delta / monotonic elapsed',
               'elapsed_seconds': elapsed, 'processes': {}}
    for name, pid in targets.items():
        summary['processes'][name] = {'pid': pid, 'cpu_seconds': previous[pid][0] - start_values[pid][0],
            'mean_cpu_percent': (previous[pid][0] - start_values[pid][0]) / elapsed * 100,
            'median_one_second_percent': statistics.median(per_target[name]),
            'max_one_second_percent': max(per_target[name]), 'rss_kib': previous[pid][1]}
    with (result / 'cpu.csv').open('w') as f:
        writer = csv.writer(f); writer.writerow(['process', 'pid', 'elapsed_s', 'cpu_time_s', 'interval_cpu_percent', 'rss_kib']); writer.writerows(rows)
    (result / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)
    print('Artifacts:', result, flush=True)
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
    for handle in handles: handle.close()
    temporary_home.cleanup()
PY
