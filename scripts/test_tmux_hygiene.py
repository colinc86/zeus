#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from tmux_hygiene import added, snapshot
import tmux_fixture_processes as fixture
from unittest.mock import patch
import shutil
import time


class TmuxHygieneTests(unittest.TestCase):
    def test_missing_directory_and_unchanged_entries(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / 'shared'
            self.assertEqual(snapshot(directory), {})
            directory.mkdir()
            (directory / 'default').touch()
            before = snapshot(directory)
            self.assertEqual(added(before, snapshot(directory)), [])
            self.assertTrue((directory / 'default').exists())

    def test_new_or_replaced_entries_fail_but_removal_does_not(self):
        before = {'default': (1, 10), 'old': (1, 11)}
        self.assertEqual(added(before, {'default': (1, 10)}), [])
        self.assertEqual(added(before, {'default': (1, 12), 'test': (1, 13)}), ['default', 'test'])

    def test_wrapper_rejects_new_entry_without_removing_it(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / f'tmux-{os.getuid()}'
            directory.mkdir()
            entry = directory / 'fixture'
            result = subprocess.run([sys.executable, '-B', str(Path(__file__).with_name('tmux_hygiene.py')),
                                     sys.executable, '-c', 'from pathlib import Path; import sys; Path(sys.argv[1]).touch()',
                                     str(entry)], env={**os.environ, 'TMUX_TMPDIR': root}, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b'created shared tmux entries', result.stderr)
            self.assertTrue(entry.exists())

    def test_process_inventory_requires_fixture_namespace_not_just_tmux(self):
        uid = os.getuid()
        lines = [f'{uid} 123 1 Sun Oct 18 00:00:00 2026 /opt/homebrew/bin/tmux -S /tmp/zmanaged_AABBCCDD/tmux.sock -f /dev/null new-session',
                 f'{uid} 456 1 Sun Oct 18 00:00:00 2026 /opt/homebrew/bin/tmux -S /tmp/tmux-501/default new-session',
                 f'{uid} 789 1 Sun Oct 18 00:00:00 2026 /bin/echo /tmp/zmanaged_AABBCCDD/tmux.sock']
        inventory = fixture.servers(fixture.processes('\n'.join(lines)))
        self.assertEqual([p.pid for p in inventory], [123])
        self.assertEqual(list(inventory.values()), [Path('/private/tmp/zmanaged_AABBCCDD')])

    def test_gui_namespace_requires_private_open_socket_and_argv_proof(self):
        process = fixture.ProcessIdentity(os.getuid(), 123, 1, 'same start',
            '/opt/homebrew/bin/tmux -u new-session -d -s zeus env ZEUS_MANAGED_OWNER=fixture claude --mcp-config /tmp/zcomposer_test/Library/Application Support/Zeus/mcp.json')
        self.assertIsNone(fixture.server_root(process))
        self.assertIsNone(fixture.server_root(process, ['/private/tmp/tmux-501/default']))
        self.assertEqual(fixture.server_root(process, ['/private/tmp/zcomposer_test/tmux/tmux-501/default']), Path('/private/tmp/zcomposer_test'))
        default = fixture.dataclasses.replace(process, command=process.command.replace('-u new-session', '-S /private/tmp/tmux-501/default new-session'))
        self.assertIsNone(fixture.server_root(default, ['/private/tmp/zcomposer_test/tmux/tmux-501/default']))

    def test_build_namespace_with_spaces_and_pid_reuse_are_safe(self):
        root = fixture.REPO / 'build/tmp/fx10'
        process = fixture.ProcessIdentity(os.getuid(), 123, 1, 'old', f'/opt/homebrew/bin/tmux -S {root}/private.sock -f /dev/null new-session')
        self.assertEqual(fixture.server_root(process), root)
        reused = fixture.dataclasses.replace(process, started='new', command='/bin/sleep 1')
        with patch.object(fixture, 'processes', side_effect=[{123: process}] + [{123: reused}] * 10), patch.object(fixture.os, 'kill') as kill:
            fixture.reap_root(root)
        kill.assert_not_called()

    def test_deleted_socket_and_root_are_reaped_by_process_lifetime(self):
        tmux = shutil.which('tmux')
        if not tmux:
            self.skipTest('tmux is not installed')
        root = Path(tempfile.mkdtemp(prefix='zfx10_', dir='/tmp')).resolve()
        socket = root / 'private.sock'
        env = {'HOME': str(root), 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'}
        try:
            subprocess.run([tmux, '-S', str(socket), '-f', '/dev/null', 'new-session', '-d', '-s', 'fixture', '/bin/sleep', '60'], env=env, check=True)
            owned = {p.pid for p, namespace in fixture.servers().items() if namespace == root}
            self.assertTrue(owned)
            socket.unlink()
            root.rmdir()
            self.assertTrue({p.pid for p, namespace in fixture.servers().items() if namespace == root})
            fixture.reap_root(root)
            self.assertFalse(owned.intersection(fixture.processes()))
        finally:
            fixture.reap_root(root)
            shutil.rmtree(root, ignore_errors=True)

    def test_wrapper_preserves_command_failure(self):
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).with_name('tmux_hygiene.py')),
                                 sys.executable, '-c', 'raise SystemExit(7)'], capture_output=True)
        self.assertEqual(result.returncode, 7)


if __name__ == '__main__':
    unittest.main()
