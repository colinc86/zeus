#!/usr/bin/env python3
"""Real Claude posts kinds, receives a rating and posts a differently-labelled look-alike.
Uses production runtime, local NLEmbedding, private tmux/HOME and localhost model only.
"""
import argparse, json, re, subprocess
import LM4LiveProbe
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host, start_model
OUT = output_dir('fb1-live')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', default='claude'); parser.add_argument('--quick', action='store_true'); parser.add_argument('--record', action='store_true')
    args = parser.parse_args(); assert args.agent == 'claude'
    LM4LiveProbe.OUT = OUT
    host = LM4LiveProbe.build_host()
    pane = Pane('claude', prefix='zlv1_', output=OUT); process = None; seen = []
    example = 'Your on-call shift starts soon. Check the rotation and handover notes before your shift.'
    def action(body):
        names = [tool['name'] for tool in body.get('tools', [])]
        if not any(name == 'zeus_say' or name.endswith('__zeus_say') for name in names):
            if 'WaitForMcpServers' in names:
                return 'WaitForMcpServers', {}
            return None, {}
        if not seen:
            seen.append('first_say')
            return 'zeus_say', {'about': 'On-call reminder', 'text': example}
        rendered = json.dumps(body.get('messages', []))
        ids = re.findall(r'\[zeus delivery_id=(d_rating_[^\]\s]+)', rendered)
        if not ids: return None, {}
        if len(seen) == 1:
            seen.append('ack_rating'); return 'zeus_ack', {'delivery_ids': [ids[-1]]}
        if len(seen) == 2:
            seen.append('lookalike_say')
            return 'zeus_say', {'about': 'Rotation heads-up', 'text': 'Your on-call rotation is about to start. Review the handover notes before taking over.', 'priority': 'high'}
        return None, {}
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'FB1 fixture complete'
    try:
        pane.server, pane.worker = start_model(Model)
        pane.env.update(ANTHROPIC_API_KEY='fb1-local-fixture', ANTHROPIC_BASE_URL=f'http://127.0.0.1:{pane.server.server_port}')
        profile = {'hasCompletedOnboarding': True, 'theme': 'dark', 'hasAcknowledgedCostThreshold': True,
                   'projects': {str(pane.project): {'hasTrustDialogAccepted': True}}}
        for p in [pane.home/'.claude.json', pane.home/'.claude/.claude.json']: p.write_text(json.dumps(profile))
        version = subprocess.check_output([pane.cli, '--version'], env=pane.env, text=True, timeout=10).strip()
        bridge = REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        with (OUT/'host.log').open('w') as log:
            process = subprocess.Popen([str(host), str(pane.root), pane.tmux, pane.cli, str(bridge)], env=pane.env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            control = HostControl(process); control.read()
            def first_card():
                state = control.call('state')
                if state['pane']:
                    screen = pane.tm('capture-pane', '-p', '-t', state['pane'])
                    if 'Quick safety check:' in screen and str(pane.project) in screen and 'Yes, I trust this folder' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Down', 'Enter')
                    elif 'Do you want to use this API key?' in screen:
                        pane.tm('send-keys', '-t', state['pane'], 'Up', 'Enter')
                return state if any(c.get('about') == 'On-call reminder' for c in state['cards']) else None
            initial = eventually(first_card, 'real Claude first about card', timeout=60)
            card = next(c for c in initial['cards'] if c.get('about') == 'On-call reminder')
            assert card['origin'] == 'unprompted' and not card.get('muteDecision'), card
            control.call('rateFirst')
            state = eventually(lambda: (s if len((s := control.call('state'))['muted']) == 1 else None),
                               'rating ack and semantic look-alike hold', timeout=75)
            held = next(c for c in state['cards'] if c.get('about') == 'Rotation heads-up')
            decision = held['muteDecision']
            assert held['origin'] == 'unprompted' and held['priority'] == 'high', held
            assert decision['engine'] == 'naturalLanguage' and decision['score'] >= decision['threshold'], decision
            assert decision['reason'] == 'looks like On-call reminder'
            assert len(state['cards']) == 2 and state['ratings'] == 1, state
            assert any(d['acked'] for d in state['deliveries']), state
            preferences = (pane.project/'Zeus/preferences.md').read_text()
            assert '## Stop' in preferences and 'On-call reminder' in preferences
            proof = scrub_paths({'agent': version, 'events': seen, 'held': held, 'preferences': preferences,
                                  'deliveries': state['deliveries'], 'isolation': 'private tmux, disposable HOME, localhost fake model, fixture key, production NLEmbedding'},
                                 {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'})
            (OUT/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            if args.record:
                destination = REPO/'TestFixtures/live/fb1'; destination.mkdir(parents=True, exist_ok=True)
                (destination/'ratings.json').write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'agent': version, 'score': decision['score'], 'engine': decision['engine']}))
    finally:
        if process: stop_host(process)
        pane.close()

if __name__ == '__main__': main()
