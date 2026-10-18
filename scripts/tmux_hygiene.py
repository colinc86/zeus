#!/usr/bin/env python3
"""Run a test command and reject new entries in the user's shared tmux directory.

This is read-only: it never connects to a socket or removes an entry.
"""
import os
import re
from pathlib import Path
import subprocess
import sys


def snapshot(directory):
    try:
        entries = list(directory.iterdir())
    except FileNotFoundError:
        return {}
    result = {}
    for path in entries:
        try:
            identity = path.lstat()
            result[path.name] = (identity.st_dev, identity.st_ino)
        except FileNotFoundError:
            pass
    return result


def added(before, after):
    return sorted(name for name, identity in after.items() if before.get(name) != identity)


def managed_servers(output=None):
    # Process inventory catches an orphan even after its socket/root was unlinked.
    if output is None:
        output = subprocess.check_output(['ps', '-axo', 'pid=,lstart=,command='], text=True)
    return {line.strip() for line in output.splitlines()
            if re.search(r'^\s*\d+\s+.*? /[^ ]*/tmux -S /(?:private/)?tmp/zmanaged_[A-Fa-f0-9]{8}/tmux\.sock ', line)}


def main():
    directories = {Path('/private/tmp') / f'tmux-{os.getuid()}'}
    if os.environ.get('TMUX_TMPDIR'):
        directories.add(Path(os.environ['TMUX_TMPDIR']).resolve() / f'tmux-{os.getuid()}')
    servers_before = managed_servers()
    before = {path: snapshot(path) for path in directories}
    result = subprocess.call(sys.argv[1:], env={**os.environ, 'ZEUS_TMUX_HYGIENE_ACTIVE': '1'})
    failures = []
    for path in directories:
        failures.extend(str(path / name) for name in added(before[path], snapshot(path)))
    failures.extend(sorted(managed_servers() - servers_before))
    if failures:
        print('FAIL: test command created shared tmux entries: ' + ', '.join(failures), file=sys.stderr)
        return 1
    print('Tmux hygiene: no new shared-directory entries or orphan managed fixture servers')
    return result


if __name__ == '__main__':
    sys.exit(main())
