#!/usr/bin/env python3
"""Offline regression: two fixture processes cannot hold the worktree lease together."""
import pathlib
import selectors
import subprocess
import sys
import tempfile
import unittest

class LiveHostLeaseTests(unittest.TestCase):
    def test_process_lifetime_serializes_and_releases_lease(self):
        with tempfile.TemporaryDirectory(prefix="zeus-lg2-lease-") as directory:
            code = """
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import LiveSupport
LiveSupport.REPO=pathlib.Path(sys.argv[2])
print('waiting', flush=True)
LiveSupport.serialize_live_hosts()
LiveSupport.serialize_live_hosts() # reentrant within a single probe
print('acquired', flush=True)
sys.stdin.readline()
"""
            children=[]
            def start():
                p=subprocess.Popen([sys.executable,"-B","-c",code,str(pathlib.Path(__file__).parent),directory],
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
                children.append(p)
                self.assertEqual(p.stdout.readline().strip(),"waiting")
                return p
            try:
                first=start()
                self.assertEqual(first.stdout.readline().strip(),"acquired")
                second=start()
                with selectors.DefaultSelector() as ready:
                    ready.register(second.stdout,selectors.EVENT_READ)
                    self.assertEqual(ready.select(timeout=0.2),[])
                    first.stdin.close();first.wait(timeout=5)
                    self.assertTrue(ready.select(timeout=5))
                    self.assertEqual(second.stdout.readline().strip(),"acquired")
                second.stdin.close();second.wait(timeout=5)
            finally:
                for p in children:
                    if p.poll() is None:p.kill();p.wait(timeout=5)
                    if p.stdin and not p.stdin.closed:p.stdin.close()
                    p.stdout.close()

if __name__ == "__main__":unittest.main()
