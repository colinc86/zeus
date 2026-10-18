#!/usr/bin/env python3
"""Opt-in real app proof. Uses a disposable home and never launches an agent deliberately."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from tmux_fixture_processes import reap_root, servers


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    app = args.app.resolve()
    if not app.is_relative_to((repo / 'build/tmp/fx10').resolve()):
        raise ValueError('Use only the worktree FX10 build')
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for flag in ('0', '1'):
        home = Path(tempfile.mkdtemp(prefix='zcomposer_', dir='/tmp')).resolve()
        (home / 'tmux').mkdir()
        environment = {'HOME': str(home), 'CFFIXED_USER_HOME': str(home), 'TMUX_TMPDIR': str(home / 'tmux'),
                       'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8', 'ZEUS_COMPOSER_GROWTH_PROBE': flag}
        process = None
        try:
            with (args.output / ('flag-' + flag + '.log')).open('w') as log:
                process = subprocess.Popen([str(app)], env=environment, stdout=log, stderr=subprocess.STDOUT)
                code = process.wait(timeout=60)
            assert code == 0, f"Probe process exited {code}"
            assert not any(root == home for root in servers().values()), 'Probe launched an agent namespace'
            artifacts = [str(path.relative_to(home)) for path in home.rglob('*') if path.is_file()]
            assert not any('managed-launch' in path or path.endswith('managed.json') for path in artifacts), artifacts
            if flag == '0':
                assert not any(path.endswith('cards.json') for path in artifacts), artifacts
            else:
                assert any(path.endswith('cards.json') for path in artifacts), 'Valid probe did not run its isolated shell'
            results.append({'flag': flag, 'exit': code, 'managed_launch_files': False, 'fixture_tmux_servers': 0,
                            'isolated_shell': flag == '1'})
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
            reap_root(home)
            shutil.rmtree(home)
    (args.output / 'proof.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Composer probe: invalid flag exits; valid flag uses isolated shell; no managed launch')


if __name__ == '__main__':
    main()
