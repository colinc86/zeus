#!/usr/bin/env python3
"""Real Claude attaches a Markdown document, then edits that same file.
Private tmux/HOME/config, scratch document, localhost model and fixture encryption key only.
"""
import argparse, json, subprocess, threading
import LM4LiveProbe
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host, start_model
OUT = output_dir('dv1-live')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--quick', action='store_true'); parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    LM4LiveProbe.OUT = OUT
    host = LM4LiveProbe.build_host()
    pane = Pane('claude', prefix='zlv1_', output=OUT); process = None; steps = []; allow_edit = threading.Event()
    summary = 'The plan describes the staged rollout to review before launch.'
    initial = '# Launch plan\n\nUse a staged rollout.\n'
    updated = '# Launch plan\n\nUse a staged rollout with a rollback checkpoint.\n'
    def action(body):
        names = [tool['name'] for tool in body.get('tools', [])]
        if not any(name.endswith('__zeus_say') or name == 'zeus_say' for name in names):
            return ('WaitForMcpServers', {}) if 'WaitForMcpServers' in names else (None, {})
        path = str(pane.project/'plan.md')
        attachment = {'kind': 'file', 'label': 'Launch plan.md', 'target': path, 'summary': summary}
        actions = [
            ('Read', {'file_path': path}),
            ('zeus_say', {'text': 'The plan recommends a staged rollout.', 'attachments': [attachment]}),
            ('Edit', {'file_path': path, 'old_string': 'Use a staged rollout.',
                      'new_string': 'Use a staged rollout with a rollback checkpoint.'}),
            ('zeus_say', {'text': 'I added a rollback checkpoint to the launch plan.', 'attachments': [attachment]})]
        if len(steps) == 2:
            assert allow_edit.wait(20), 'Host must observe the original card/file before editing'
        if len(steps) < len(actions):
            result = actions[len(steps)]; steps.append(result[0]); return result
        return None, {}
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'DV1 complete'
    try:
        (pane.project/'plan.md').write_text(initial)
        # Only the disposable HOME is changed. Permit the one scripted native Edit; no shell tool is used.
        (pane.home/'.claude/settings.json').write_text(json.dumps({'permissions': {'allow': ['Edit']}}))
        pane.server, pane.worker = start_model(Model)
        pane.env.update(ANTHROPIC_API_KEY='dv1-local-fixture', ANTHROPIC_BASE_URL=f'http://127.0.0.1:{pane.server.server_port}')
        profile = {'hasCompletedOnboarding': True, 'theme': 'dark', 'hasAcknowledgedCostThreshold': True,
                   'projects': {str(pane.project): {'hasTrustDialogAccepted': True}}}
        for path in [pane.home/'.claude.json', pane.home/'.claude/.claude.json']: path.write_text(json.dumps(profile))
        version = subprocess.check_output([pane.cli, '--version'], env=pane.env, text=True, timeout=10).strip()
        bridge = REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        with (OUT/'host.log').open('w') as log:
            process = subprocess.Popen([str(host), str(pane.root), pane.tmux, pane.cli, str(bridge)], env=pane.env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            control = HostControl(process); control.read()
            def received():
                state = control.call('state')
                if state['pane']:
                    screen = pane.tm('capture-pane', '-p', '-t', state['pane'])
                    if 'Quick safety check:' in screen and str(pane.project) in screen and 'Yes, I trust this folder' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Down', 'Enter')
                    elif 'Do you want to use this API key?' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Up', 'Enter')
                return state if state['cards'] else None
            before = eventually(received, 'real Claude attaches the original Markdown file', timeout=60)
            assert len(before['cards']) == 1 and (pane.project/'plan.md').read_text() == initial, before
            first = before['cards'][0]
            assert first['attachments'][0]['summary'] == summary, first
            assert first['attachments'][0]['target'] == str(pane.project/'plan.md'), first
            allow_edit.set()
            state = eventually(lambda: s if len((s := control.call('state'))['cards']) == 2 else None,
                               'native Edit -> same-path file update -> changed takeaway', timeout=60)
            assert steps == ['Read', 'zeus_say', 'Edit', 'zeus_say'], steps
            assert (pane.project/'plan.md').read_text() == updated
            assert state['cards'][0] == first, 'Updating the file must not replace or rewrite the original card'
            assert state['cards'][1]['attachments'][0]['target'] == first['attachments'][0]['target']
            results = [block for body in Model.requests for message in body.get('messages', [])
                       if isinstance(message.get('content'), list) for block in message['content']
                       if block.get('type') == 'tool_result']
            assert not any(block.get('is_error') for block in results), results
            proof = scrub_paths({'agent': version, 'tools': steps, 'before': first, 'after': state['cards'],
                'initial_file': initial, 'updated_file': updated, 'same_path': True,
                'viewer': 'Not exercised by this headless probe; native viewer rendering/refresh requires separate app tests.',
                'isolation': 'private tmux, disposable HOME/config, scratch document, localhost model, fixture key'},
                {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'})
            (OUT/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            if args.record:
                destination = REPO/'TestFixtures/live/dv1'; destination.mkdir(parents=True, exist_ok=True)
                (destination/'document.json').write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'agent': version, 'same_path_edited': True, 'cards': 2}))
    finally:
        allow_edit.set()
        if process: stop_host(process)
        pane.close()

if __name__ == '__main__': main()
