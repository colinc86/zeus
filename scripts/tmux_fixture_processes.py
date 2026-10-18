#!/usr/bin/env python3
"""Process-backed fixture inventory. Socket existence is never ownership evidence."""
import dataclasses
import os
from pathlib import Path
import re
import signal
import subprocess
import time

REPO = Path(__file__).resolve().parents[1]
# Names reserved by the checked-in native and managed-process fixtures.
PREFIX = r'z(?:composer|managed|pc1|sa[1-4]|ac1|lv1|cy1|fx10|live|l3|last|m4b|s3|ob1|n1|tmux|nsui)_[A-Za-z0-9_-]+'


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    uid: int
    pid: int
    parent: int
    started: str
    command: str


def processes(output=None):
    if output is None:
        output = subprocess.check_output(['/bin/ps', '-axo', 'uid=,pid=,ppid=,lstart=,command='], text=True)
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9 or not all(v.isdigit() for v in fields[:3]):
            continue
        uid, pid, parent = map(int, fields[:3])
        result[pid] = ProcessIdentity(uid, pid, parent, ' '.join(fields[3:8]), fields[8])
    return result


def fixture_root(path):
    path = str(path)
    match = re.match(r'^/(?:private/)?tmp/(' + PREFIX + r')(?:/|$)', path)
    if match:
        return Path('/private/tmp') / match[1]
    base = str(REPO / 'build/tmp') + '/'
    if path.startswith(base) and '..' not in Path(path).parts:
        parts = path[len(base):].split('/')
        if len(parts) > 1 and parts[0]:
            return Path(base) / parts[0]
    return None


def server_root(process, socket_paths=()):
    if process.uid != os.getuid() or process.pid <= 1:
        return None
    executable = process.command.split(' ', 1)[0]
    if not executable.startswith('/') or Path(executable).name != 'tmux':
        return None
    # Inspect only actual namespace/config arguments, never an incidental path in a shell command.
    command = re.search(r' (?:new-session|new|start-server|attach-session|attach|list-sessions|ls|has-session|kill-server|split-window|respawn-pane)(?: |$)', process.command)
    options = process.command[:command.start()] if command else process.command
    match = re.search(r'(?:^| )-S (/.+?(?:\.sock|/(?:default|sock)))(?= |$)', options)
    if match:
        return fixture_root(match[1])
    if ' -S ' in options:
        return None
    match = re.search(r'(?:^| )TMUX_TMPDIR=(/[^ ]+)', options)
    if match:
        return fixture_root(match[1])
    # Managed GUI fixtures use TMUX_TMPDIR internally; ps preserves their launch argv,
    # including the managed owner and their explicit MCP configuration path.
    if ' new-session ' in process.command and ' ZEUS_MANAGED_OWNER=' in process.command:
        match = re.search(r' --mcp-config (/(?:private/)?tmp/' + PREFIX + r'/)', process.command)
        if match:
            root = fixture_root(match[1])
            if any(fixture_root(path) == root for path in socket_paths):
                return root
    return None


def socket_paths(pid):
    result = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-U', '-Fn'], capture_output=True, text=True, timeout=5)
    return [line[1:].removesuffix(' (deleted)') for line in result.stdout.splitlines() if line.startswith('n/')]


def servers(snapshot=None):
    result = {}
    for process in (processes() if snapshot is None else snapshot).values():
        root = server_root(process)
        if root is None and process.uid == os.getuid() and process.command.split(' ', 1)[0].endswith('/tmux') and ' ZEUS_MANAGED_OWNER=' in process.command:
            root = server_root(process, socket_paths(process.pid))
        if root is not None:
            result[process] = root
    return result


def reap_root(root):
    """Reap only matching argv-proven fixture servers and their captured child lifetimes."""
    root = Path(root)
    if root.is_symlink() or fixture_root(str(root) + '/') != root.resolve():
        raise ValueError('Not an explicit fixture namespace')
    root = root.resolve()
    snapshot = processes()
    owned = {process.pid: process for process, namespace in servers(snapshot).items() if namespace == root}
    while True:
        children = {p.pid: p for p in snapshot.values() if p.uid == os.getuid() and p.parent in owned and p.pid not in owned}
        if not children:
            break
        owned.update(children)

    def current():
        latest = processes()
        return [pid for pid, old in owned.items() if (now := latest.get(pid)) and now.uid == old.uid and now.started == old.started]

    for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, 2)):
        for pid in current():
            # Recheck immediately before every signal; never signal a group containing unrelated clients.
            if pid in current():
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + grace
        while current() and time.monotonic() < deadline:
            time.sleep(.05)
        if not current():
            return
    raise RuntimeError('Fixture-owned process lifetime survived cleanup')
