#!/usr/bin/env python3
"""Real managed Claude resumes and consumes one durable restart notice per launch."""
import argparse
import json
import re
import subprocess
import LM4LiveProbe
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host, start_model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--quick', action='store_true')
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    out = output_dir('fx15')
    LM4LiveProbe.OUT = out
    host = LM4LiveProbe.build_host()
    pane = Pane('claude', prefix='zlv1_', output=out)
    process = None
    seen = set()
    def action(body):
        text = json.dumps(body.get('messages', []), ensure_ascii=False)
        matches = re.findall(r'\[zeus delivery_id=(restart_[^\s\]]+)', text)
        for delivery_id in matches:
            if delivery_id not in seen:
                assert 'Timers and scheduled checks you set before the restart are gone.' in text
                seen.add(delivery_id)
                return 'zeus_ack', {'delivery_ids': [delivery_id]}
        return None, {}
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'FX15 ready'
    try:
        pane.server, pane.worker = start_model(Model)
        pane.env.update(ANTHROPIC_API_KEY='fx15-local-fixture', ANTHROPIC_BASE_URL=f'http://127.0.0.1:{pane.server.server_port}')
        profile = {'hasCompletedOnboarding': True, 'theme': 'dark', 'hasAcknowledgedCostThreshold': True,
                   'projects': {str(pane.project): {'hasTrustDialogAccepted': True}}}
        for path in [pane.home/'.claude.json', pane.home/'.claude/.claude.json']:
            path.write_text(json.dumps(profile))
        version = subprocess.check_output([pane.cli, '--version'], env=pane.env, text=True, timeout=10).strip()
        bridge = REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        with (out/'host.log').open('w') as log:
            process = subprocess.Popen([str(host), str(pane.root), pane.tmux, pane.cli, str(bridge)],
                                       env=pane.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            control = HostControl(process); control.read()
            def ready():
                state = control.call('state')
                if state['pane']:
                    try:
                        screen = pane.tm('capture-pane', '-p', '-t', state['pane'])
                    except subprocess.CalledProcessError:
                        return None  # The old pane is removed during the serialized restart.
                    if 'Quick safety check:' in screen and str(pane.project) in screen and 'Yes, I trust this folder' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Down', 'Enter')
                    elif 'Do you want to use this API key?' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Up', 'Enter')
                return state if state['sessions'] == 1 and '.idle' in state['status'] else None
            before = eventually(ready, 'fresh managed Claude idle', timeout=60)
            assert not before['deliveries']
            for count in (1, 2):
                control.call('restart')
                def received():
                    state = ready()
                    return state if state and len(state['deliveries']) == count and all(d['acked'] for d in state['deliveries']) else None
                state = eventually(received, f'resume {count} -> real model -> zeus_ack -> receipt', timeout=90)
                assert state['nativeID'] == before['nativeID'], state
                assert state['budget'] == before['budget'] == 6, state
                assert len(state['receipts']) == count and len(seen) == count, state
                assert all(d['kind'] == 'restart' and d['attempts'] == 1 for d in state['deliveries']), state
            proof = scrub_paths({'agent': version, 'fresh_notices': 0, 'resumed_notices': 2,
                'same_native_conversation': True, 'budget_unchanged': True, 'state': state,
                'isolation': 'private tmux, disposable HOME/config, localhost model, fixture key'},
                {str(pane.root): '/FIXTURE', str(REPO): '/WORKTREE'})
            (out/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            if args.record:
                target = REPO/'TestFixtures/live/fx15'; target.mkdir(parents=True, exist_ok=True)
                (target/'restart.json').write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'agent': version, 'restart_notices': len(seen)}))
    finally:
        if process: stop_host(process)
        pane.close()


if __name__ == '__main__':
    main()
