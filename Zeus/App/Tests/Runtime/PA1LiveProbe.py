#!/usr/bin/env python3
"""Real Claude consumes runtime-created briefs and rule triggers; local model only."""
import argparse
import json
import re
import subprocess
import LM4LiveProbe
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host, start_model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scenario', choices=['pa1-brief', 'pa1-trigger'], required=True)
    parser.add_argument('--quick', action='store_true')
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    out = output_dir(args.scenario)
    LM4LiveProbe.OUT = out
    host = LM4LiveProbe.build_host()
    pane = Pane('claude', prefix='zlv1_', output=out)
    process = None
    steps = {}
    tools = []
    def action(body):
        text = json.dumps(body.get('messages', []), ensure_ascii=False)
        envelopes = list(re.finditer(r'\[zeus delivery_id=([^\s\]]+)', text))
        envelopes = [e for e in envelopes if e.group(1).startswith(('brief_', 'trigger_'))]
        if not envelopes:
            return None, {}
        envelope = envelopes[-1]
        delivery_id = envelope.group(1)
        content = text[envelope.start():]
        index = steps.get(delivery_id, 0)
        if delivery_id.startswith('brief_'):
            quiet = delivery_id != 'brief_2026-10-14'
            sequence = [] if quiet else [('zeus_present', {'title': 'Today', 'body': 'Review the synthetic project plan before the fixture meeting.', 'about': 'Morning brief'})]
        elif delivery_id.startswith('trigger_'):
            rule = re.search(r'· rule (rule_[A-Za-z0-9-]+)', content)
            assert rule, content
            shadow = 'Rule trigger (shadow' in content
            sequence = [('zeus_rule_shadow' if shadow else 'zeus_rule_acted',
                         {'ruleID': rule.group(1), 'wouldHave' if shadow else 'did': 'Prepared a synthetic project recap',
                          **({} if shadow else {'undo': 'Discard the synthetic recap'})})]
        else:
            return None, {}
        sequence.append(('zeus_ack', {'delivery_ids': [delivery_id]}))
        if index >= len(sequence):
            return None, {}
        result = sequence[index]
        steps[delivery_id] = index + 1
        tools.append(result[0])
        return result
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'PA1 ready'
    try:
        pane.server, pane.worker = start_model(Model)
        pane.env.update(ANTHROPIC_API_KEY='pa1-local-fixture', ANTHROPIC_BASE_URL=f'http://127.0.0.1:{pane.server.server_port}')
        profile = {'hasCompletedOnboarding': True, 'theme': 'dark', 'hasAcknowledgedCostThreshold': True,
                   'projects': {str(pane.project): {'hasTrustDialogAccepted': True}}}
        for path in [pane.home/'.claude.json', pane.home/'.claude/.claude.json']:
            path.write_text(json.dumps(profile))
        version = subprocess.check_output([pane.cli, '--version'], env=pane.env, text=True, timeout=10).strip()
        bridge = REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        with (out/'host.log').open('w') as log:
            process = subprocess.Popen([str(host), str(pane.root), pane.tmux, pane.cli, str(bridge), args.scenario],
                                       env=pane.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            control = HostControl(process); control.read()
            def ready():
                state = control.call('state')
                if state['pane']:
                    screen = pane.tm('capture-pane', '-p', '-t', state['pane'])
                    if 'Quick safety check:' in screen and str(pane.project) in screen and 'Yes, I trust this folder' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Down', 'Enter')
                    elif 'Do you want to use this API key?' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Up', 'Enter')
                return state if state['sessions'] == 1 and '.idle' in state['status'] else None
            eventually(ready, 'real Claude ready', timeout=60)
            control.call('brief' if args.scenario == 'pa1-brief' else 'triggers')
            expected = 1 if args.scenario == 'pa1-brief' else 2
            def complete():
                state = control.call('state')
                (out/'state.private.json').write_text(json.dumps(state, indent=2))
                return state if len(state['deliveries']) == expected and all(d['acked'] for d in state['deliveries']) else None
            state = eventually(complete, 'proactive delivery -> real MCP tool -> acknowledgment', timeout=90)
            assert len(state['receipts']) == expected, state
            if args.scenario == 'pa1-brief':
                assert len(state['cards']) == 1 and state['cards'][0]['kind'] == 'content' and state['cards'][0]['about'] == 'Morning brief', state
                assert state['cards'][0]['origin'] == 'unprompted', state
                assert "yesterday's summary" not in state['deliveries'][0]['content'], state
                control.call('brief')
                assert len(control.call('state')['deliveries']) == 1
                control.call('nextBrief'); expected = 2
                state = eventually(complete, 'nothing matters -> quiet ack, no extra card', timeout=90)
                assert len(state['cards']) == 1 and tools.count('zeus_present') == 1, state
            else:
                assert sorted(a['kind'] for a in state['ruleActions']) == ['acted', 'shadow'], state
                assert not state['cards'], state
                assert tools.count('zeus_rule_acted') == 1 and tools.count('zeus_rule_shadow') == 1
            assert all(d['attempts'] == 1 for d in state['deliveries']), state
            proof = scrub_paths({'agent': version, 'scenario': args.scenario, 'tools': tools, 'state': state,
                'isolation': 'private tmux, disposable HOME/config, localhost model, fixture encryption key; no external action'},
                {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'})
            (out/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            if args.record:
                target = REPO/'TestFixtures/live/pa1'; target.mkdir(parents=True, exist_ok=True)
                (target/(args.scenario+'.json')).write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'scenario': args.scenario, 'agent': version, 'tools': tools}))
    finally:
        (out/'policy.json').write_text(json.dumps({'steps': steps, 'tools': tools, 'requests': len(Model.requests)}, indent=2)+'\n')
        if process:
            stop_host(process)
        pane.close()


if __name__ == '__main__':
    main()
