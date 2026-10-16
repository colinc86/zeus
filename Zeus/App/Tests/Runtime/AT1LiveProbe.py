#!/usr/bin/env python3
"""Real Claude retries a rejected file attachment with its own synopsis.
Private tmux/HOME/config, scratch document, localhost model and fixture encryption key only.
"""
import argparse, json, subprocess
import LM4LiveProbe
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host, start_model
OUT = output_dir('at1-live')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--quick', action='store_true'); parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    LM4LiveProbe.OUT = OUT
    host = LM4LiveProbe.build_host()
    pane = Pane('claude', prefix='zlv1_', output=OUT); process = None; steps = []
    summary = 'The draft explains the staged rollout and highlights the two risks to review before launch.'
    rejected = []
    def action(body):
        names = [tool['name'] for tool in body.get('tools', [])]
        if not any(name.endswith('__zeus_say') or name == 'zeus_say' for name in names):
            return ('WaitForMcpServers', {}) if 'WaitForMcpServers' in names else (None, {})
        attachment = {'kind': 'file', 'label': 'Launch plan', 'target': str(pane.project/'plan.md')}
        if not steps:
            steps.append('missing_summary')
            return 'zeus_say', {'text': 'The launch plan is ready; review the rollout risks.', 'attachments': [attachment]}
        if len(steps) == 1:
            results = [block for message in body.get('messages', []) if isinstance(message.get('content'), list)
                       for block in message['content'] if block.get('type') == 'tool_result']
            errors = [block for block in results if 'Each file or folder attachment needs a summary:' in json.dumps(block)]
            assert errors and errors[-1].get('is_error'), 'Real Claude must receive the summary validation error before retrying'
            rejected.append(errors[-1]); steps.append('retry_with_summary')
            attachment['summary'] = summary
            return 'zeus_say', {'text': 'The launch plan is ready; review the rollout risks.', 'attachments': [attachment]}
        return None, {}
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'AT1 complete'
    try:
        (pane.project/'plan.md').write_text('# Synthetic launch plan\nStaged rollout with two risks to review.\n')
        pane.server, pane.worker = start_model(Model)
        pane.env.update(ANTHROPIC_API_KEY='at1-local-fixture', ANTHROPIC_BASE_URL=f'http://127.0.0.1:{pane.server.server_port}')
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
            state = eventually(received, 'rejected attachment -> real Claude retry -> stored synopsis', timeout=60)
            assert steps == ['missing_summary', 'retry_with_summary'] and len(rejected) == 1, steps
            assert len(state['cards']) == 1, state
            card = state['cards'][0]
            assert card['attachments'][0]['summary'] == summary, card
            assert card['attachments'][0]['target'] == str(pane.project/'plan.md'), card
            proof = scrub_paths({'agent': version, 'steps': steps, 'rejection': rejected[0], 'card': card,
                'thread_card_count': 1, 'isolation': 'private tmux, disposable HOME/config, scratch document, localhost model, fixture key'},
                {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'})
            (OUT/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            if args.record:
                destination = REPO/'TestFixtures/live/at1'; destination.mkdir(parents=True, exist_ok=True)
                (destination/'attachment.json').write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'agent': version, 'rejected_then_retried': True, 'cards': 1}))
    finally:
        if process: stop_host(process)
        pane.close()

if __name__ == '__main__': main()
