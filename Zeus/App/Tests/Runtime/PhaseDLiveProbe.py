#!/usr/bin/env python3
"""Real Claude Phase D tools, private tmux/HOME, localhost model, synthetic journal only."""
import json, re, subprocess
from LM2LiveProbe import build_host
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host

OUT = output_dir('lm2d-live')

def main():
    host = build_host()
    pane = Pane('claude', prefix='zlv1_', output=OUT)
    process = None
    pending, seen = [], []
    def action(body):
        if pending:
            name, args = pending.pop(0)
            # Delivery IDs come from the actual production reflection envelope.
            if name == 'zeus_ack':
                pattern = r'undo_rule_action_[A-Fa-f0-9-]+' if args.get('fixture_undo') else r'd_reflection_[0-9]{8}'
                match = re.search(pattern, json.dumps(body.get('messages', [])))
                assert match, 'Model did not receive the reflection envelope'
                args = {'delivery_ids': [match.group(0)]}
            seen.append(name)
            return name, args
        return None, {}
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'Phase D fixture ready'
    try:
        bridge = REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        config = pane.root/'mcp.json'
        config.write_text(json.dumps({'mcpServers': {'zeus': {'command': str(bridge), 'args': ['--agent', 'claude', '--socket', str(pane.root/'bridge.sock')]}}}))
        with (OUT/'host.log').open('w') as log:
            process = subprocess.Popen([str(host), str(pane.root), pane.tmux], env=pane.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            control = HostControl(process); control.read()
            pane.start(Model, lambda base: [pane.cli, '--mcp-config', str(config), '--model', 'claude-haiku-4-5', '--permission-mode', 'manual', '--allowedTools', 'mcp__zeus__*'], lambda base: {'ANTHROPIC_API_KEY': 'lm2d-local-fixture', 'ANTHROPIC_BASE_URL': base})
            pane.onboard()
            eventually(lambda: control.call('state')['sessions'] == 1, 'real bridge connects', timeout=45)
            pane.send('Begin the isolated Phase D fixture.')
            eventually(lambda: 'Phase D fixture ready' in pane.plain(), 'native warmup ends', timeout=45)
            evidence = ['synthetic-editor', 'synthetic-editor-yesterday']
            pending.extend([
                ('zeus_get_journal', {'query': 'synthetic', 'kinds': ['focus']}),
                ('zeus_propose_rules', {'rules': [
                    {'sentence': 'Keep synthetic updates concise', 'kind': 'passive', 'evidence': evidence},
                    {'sentence': 'Buy synthetic supplies', 'trigger': {'kind': 'spend'}, 'kind': 'acts', 'evidence': evidence}]}),
                ('zeus_ack', {}), ('zeus_say', {'text': 'Synthetic journal reviewed.'})])
            Model.completion_text = 'Phase D reflection finished'
            control.call('reflect')
            state = eventually(lambda: (s if len((s := control.call('state'))['rules']) == 2 and not pending else None), 'real journal answer and rule proposal', timeout=90)
            passive, spend = state['rules']
            assert passive['status'] == 'active' and spend['status'] == 'shadow', state
            eventually(lambda: 'Phase D reflection finished' in pane.plain(), 'first native turn completes', timeout=45)
            state = control.call('approvePassive')
            Model.completion_text = 'Phase D actions finished'
            pending.extend([
                ('zeus_rule_shadow', {'ruleID': spend['id'], 'wouldHave': 'Buy synthetic supplies', 'amount': 14, 'currency': 'EUR'}),
                ('zeus_rule_acted', {'ruleID': passive['id'], 'did': 'Kept the synthetic recap concise', 'undo': 'Restore the synthetic recap wording'}),
                ('zeus_say', {'text': 'Synthetic rule actions recorded.'})])
            pane.send('Exercise the synthetic rule actions now.')
            def acted_state():
                s = control.call('state')
                return s if any(a['kind'] == 'acted' for a in s['actions']) else None
            state = eventually(acted_state, 'real acted tool received', timeout=90)
            assert next(r for r in state['rules'] if r['id'] == spend['id'])['status'] == 'shadow'
            eventually(lambda: 'Phase D actions finished' in pane.plain(), 'action turn completes', timeout=45)
            pending.extend([('zeus_ack', {'fixture_undo': True}), ('zeus_say', {'text': 'Synthetic recap wording restored.'})])
            state = control.call('undo')
            def undo_received():
                s = control.call('state')
                return s if any(d['id'].startswith('undo_rule_action_') and d['acked'] for d in s['deliveries']) else None
            state = eventually(undo_received, 'real Claude consumes and acknowledges Undo', timeout=90)
            assert any('Restore the synthetic recap wording' in json.dumps(b.get('messages', [])) for b in Model.requests)

            assert any(o['outcome'] == 'undone' for o in state['outcomes']), state
            assert any(a['state'] == 'undoRequested' for a in state['actions']), state
            journal_receipts = [r for r in state['receipts'] if r['payload']['value']['details'].get('kind') == 'journal_answer']
            assert len(journal_receipts) == 1, state
            answer = json.loads(journal_receipts[0]['payload']['value']['text'])
            assert answer['items'] and 'synthetic' in answer['items'][0]['text']
            assert any('journal_answer_' in json.dumps(b.get('messages', [])) for b in Model.requests), 'Claude did not consume the journal result'
            proof = scrub_paths({'passed': True, 'agent': pane.version, 'tools': seen, 'state': state,
                'isolation': 'private tmux, disposable HOME, localhost model, fixed fixture key; no user credentials', 'pane': pane.snapshot()}, {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'})
            target = REPO/'TestFixtures/live/lm2d'; target.mkdir(parents=True, exist_ok=True)
            (target/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'agent': pane.version, 'tools': seen}))
    finally:
        if process: stop_host(process)
        pane.close()

if __name__ == '__main__': main()
