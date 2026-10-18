#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from tmux_hygiene import added, snapshot, managed_servers


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

    def test_orphan_inventory_is_specific_and_catches_unlinked_sockets(self):
        fixture = '123 Sun Oct 18 00:00:00 2026 /opt/homebrew/bin/tmux -S /tmp/zmanaged_AABBCCDD/tmux.sock -f /dev/null new-session'
        user = '456 Sun Oct 18 00:00:00 2026 /opt/homebrew/bin/tmux -S /tmp/tmux-501/default new-session'
        unrelated = '789 Sun Oct 18 00:00:00 2026 /bin/echo /tmp/zmanaged_AABBCCDD/tmux.sock'
        self.assertEqual(managed_servers('\n'.join([fixture, user, unrelated])), {fixture})

    def test_wrapper_preserves_command_failure(self):
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).with_name('tmux_hygiene.py')),
                                 sys.executable, '-c', 'raise SystemExit(7)'], capture_output=True)
        self.assertEqual(result.returncode, 7)


if __name__ == '__main__':
    unittest.main()
