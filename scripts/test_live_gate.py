#!/usr/bin/env python3
"""Offline gate/transport regressions; private files, no agents or user tmux."""
import http.client
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('live_gate',pathlib.Path(__file__).with_name('live_gate.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
from LiveSupport import create_root, isolated_environment, scrub_paths, cleanup_root, start_model, stream_reply

class GateTests(unittest.TestCase):
    def test_final_table_and_manifest_report_failure_or_missing_agent(self):
        import contextlib,io
        for installed in (True,False):
            with tempfile.TemporaryDirectory() as temp, patch.object(gate,'ROOT',pathlib.Path(temp)), patch.object(gate.shutil,'which',side_effect=lambda name:'/bin/fixture' if name=='tmux' or installed else None), patch.object(gate,'run_bounded',side_effect=[('PASS',0),('FAIL',7)]), patch.object(gate.subprocess,'check_output',return_value='fixture-revision\n'):
                capture=io.StringIO()
                with contextlib.redirect_stdout(capture):result=gate.main(['--only','ac1','--agents','claude'])
                manifest=json.loads(next(pathlib.Path(temp).rglob('summary.json')).read_text())
                self.assertEqual(result,1 if installed else 0)
                self.assertEqual(manifest['rows'][0]['result'],'FAIL' if installed else 'SKIP')
                self.assertIn('| Probe | Agent | Result | Seconds | Evidence |',capture.getvalue())
    def test_selection_and_missing_cli_are_per_row(self):
        jobs=gate.plan(('claude','codex'),('sa2','sa4','e2e'),{'claude'})
        self.assertEqual(jobs,[('sa2','codex','skip'),('sa4','claude','run'),('sa4','codex','skip'),('e2e','—','run')])
        self.assertEqual(gate.comma_values('SA4,sa4,ac1',gate.PROBES),('sa4','ac1'))
        with self.assertRaises(Exception):gate.comma_values('bad',gate.PROBES)
    def test_quick_and_record_argv_are_distinct(self):
        out=pathlib.Path('/tmp/private-proof')
        self.assertIn('--quick',gate.command('sa4','claude',out,True,False))
        self.assertNotIn('--record',gate.command('sa4','claude',out,True,False))
        self.assertIn('--native-updater',gate.command('pc1','claude',out,False,True))
        self.assertNotIn('scripts/build.sh',gate.command('e2e','—',out,False,False))
    def test_proactive_probes_are_in_quick_gate(self):
        for probe in ('pa1-brief', 'pa1-trigger'):
            self.assertEqual(gate.PROBES[probe], ('claude',))
            command = gate.command(probe, 'claude', pathlib.Path('/tmp/fixture'), True, False)
            self.assertIn('--quick', command)
            self.assertEqual(command[command.index('--scenario') + 1], probe)

    def test_document_probe_is_in_quick_gate(self):
        self.assertIn(('dv1', 'claude', 'run'), gate.plan(('claude',), tuple(gate.PROBES), {'claude'}))
        argv = gate.command('dv1', 'claude', pathlib.Path('/tmp/private-proof'), True, False)
        self.assertIn('Zeus/App/Tests/Runtime/DV1LiveProbe.py', argv)
        self.assertIn('--quick', argv)
        self.assertNotIn('--record', argv)

    def test_private_environment_does_not_copy_credentials_or_tmux(self):
        root=create_root('zsa4_')
        try:
            with patch.dict(os.environ,{'ANTHROPIC_API_KEY':'never-copy','TMUX':'human-server','CODEX_HOME':'human-profile'}):
                env=isolated_environment(root/'home')
            self.assertNotIn('ANTHROPIC_API_KEY',env);self.assertNotIn('TMUX',env)
            self.assertEqual(env['CFFIXED_USER_HOME'],str(root/'home'))
            self.assertEqual(env['CODEX_HOME'],str(root/'home/.codex'))
            self.assertEqual(env['TMUX_TMPDIR'],str(root/'home/tmux'))
        finally:cleanup_root(root)
    def test_scrubbing_handles_both_mac_socket_aliases(self):
        value={'screen':'/private/tmp/zsa4_demo/project /tmp/zsa4_demo/project','nested':['/CLI/bin/claude']}
        self.assertEqual(scrub_paths(value,{'/private/tmp/zsa4_demo':'/FIXTURE','/CLI/bin/claude':'/CLI/claude'}),
                         {'screen':'/FIXTURE/project /FIXTURE/project','nested':['/CLI/claude']})
    def test_cleanup_refuses_nonfixture_and_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):cleanup_root(pathlib.Path(temp))
            link=pathlib.Path(temp)/'zsa4_link';link.symlink_to(temp)
            with self.assertRaises(ValueError):cleanup_root(link)
    def test_cleanup_targets_only_private_pane_lifetimes(self):
        import types,LiveSupport
        root=create_root('zsa4_');(root/'tmux.sock').touch()
        alive={11:'pane lifetime',12:'agent lifetime'};calls=[]
        def run(argv,**kwargs):
            calls.append(argv)
            if argv[0]=='/bin/ps':out=alive.get(int(argv[2]),'')
            elif argv[0]=='/usr/bin/pgrep':out='12' if argv[2]=='11' else ''
            elif 'list-panes' in argv:out='11'
            else:out=''
            return types.SimpleNamespace(stdout=out,returncode=0)
        def kill(pid,sig):alive.pop(pid,None)
        with patch.object(LiveSupport.shutil,'which',return_value='/fixture/tmux'),patch.object(LiveSupport.subprocess,'run',side_effect=run),patch.object(LiveSupport.os,'getpgid',side_effect=lambda pid:pid),patch.object(LiveSupport.os,'killpg',side_effect=kill):
            cleanup_root(root)
        self.assertFalse(root.exists());self.assertFalse(alive)
        tmux_calls=[c for c in calls if c[0]=='/fixture/tmux']
        self.assertTrue(tmux_calls);self.assertTrue(all(c[1:3]==['-S',str(root/'tmux.sock')] for c in tmux_calls))
    def test_failed_and_timed_out_processes_fail_without_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            out=pathlib.Path(temp)
            self.assertEqual(gate.run_bounded([sys.executable,'-c','raise SystemExit(7)'],os.environ.copy(),out,2),('FAIL',7))
            self.assertEqual(gate.run_bounded([sys.executable,'-c','import time; time.sleep(20)'],os.environ.copy(),out,.05),('TIMEOUT',None))
    def test_recorded_fixture_bytes_untouched_by_scrubbing_gate_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            root=pathlib.Path(temp); fixture=root/'recorded.json';fixture.write_text('original fixture\n')
            evidence=root/'evidence';evidence.mkdir();registry=evidence/'namespaces.private';registry.write_text(json.dumps('/private/tmp/zsa4_demo')+'\n')
            (evidence/'proof.json').write_text(json.dumps({'path':'/tmp/zsa4_demo/project'}))
            gate.scrub_evidence(evidence,registry)
            self.assertEqual(fixture.read_text(),'original fixture\n');self.assertIn('/FIXTURE/project',(evidence/'proof.json').read_text())
    def test_streams_preserve_tool_namespaces_and_terminal_text(self):
        import http.server
        for protocol in ('anthropic','responses','chat'):
            for tool in (None,'zeus_ack'):
                class Handler(http.server.BaseHTTPRequestHandler):
                    def log_message(self,*_):pass
                    def do_POST(self):
                        self.rfile.read(int(self.headers.get('Content-Length','0')))
                        stream_reply(self,protocol,{'model':'fixture'},tool,{'delivery_ids':['d_fixture']},'native complete','zeus')
                server,worker=start_model(Handler)
                try:
                    client=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=5)
                    client.request('POST','/',body=b'{}');reply=client.getresponse();body=reply.read().decode();client.close()
                    self.assertEqual(reply.status,200)
                    self.assertIn('zeus_ack' if tool else 'native complete',body)
                    if tool and protocol=='responses':self.assertIn('"namespace": "zeus"',body)
                    self.assertIn('message_stop' if protocol=='anthropic' else '[DONE]' if protocol=='chat' else 'response.completed',body)
                finally:server.shutdown();server.server_close();worker.join(timeout=2)

if __name__=='__main__':unittest.main()
