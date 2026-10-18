#!/usr/bin/env python3
"""Two-week synthetic reflection through real Claude/native Write and production MCP rules/ack.
The localhost model scripts tool choices; it does not measure a remote model's reasoning quality.
"""
import argparse, json, re, subprocess
import LM2LiveProbe
from LiveSupport import REPO, Pane, Model, HostControl, eventually, output_dir, scrub_paths, stop_host
OUT = output_dir('rf1-live')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--quick', action='store_true'); parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    LM2LiveProbe.OUT = OUT
    host = LM2LiveProbe.build_host(); pane = Pane('claude', prefix='zlv1_', output=OUT)
    process = None; steps = []; cited = []; fetched = []
    def action(body):
        rendered = json.dumps(body.get('messages', []))
        delivery = re.search(r'd_reflection_[0-9]{8}', rendered)
        if not delivery: return None, {}
        if delivery.group(0) not in fetched:
            fetched.append(delivery.group(0))
            return "zeus_get_learnings", {"id": delivery.group(0)}
        if not cited:
            # Take evidence from the production digest, never from the fixture seed directly.
            evidence = re.search(r'\[(j_\d+_\w+) [^\]]+, (j_\d+_\w+) [^\]]+\]', rendered)
            assert evidence, 'Digest must cite different observed local days'
            cited.extend(evidence.groups())
        targets = [
            ('Write', {'file_path': str(pane.project/'Notes/about-you.md'), 'content': '# About you\n\n14 October: Morning planning comes before focused project work, based on repeated observed days.\n'}),
            ('Write', {'file_path': str(pane.project/'Notes/patterns.md'), 'content': '# Patterns\n\n14 October: Mail and Calendar precede the editor around nine on observed mornings. These repeated observations support a quiet project-work window.\n'}),
            ('zeus_get_rules', {}),
            ('zeus_propose_rules', {'rules': [{'sentence': 'Keep routine updates quiet during morning project work', 'kind': 'passive', 'trigger': {'apps': ['com.apple.Xcode']}, 'evidence': cited}]}),
            ('zeus_ack', {'delivery_ids': [delivery.group(0)]})]
        if len(steps) < len(targets):
            target = targets[len(steps)]; steps.append(target[0]); return target
        return None, {}
    Model.action = action; Model.stage = 0; Model.requests = []; Model.completion_text = 'RF1 fixture complete'
    try:
        bridge = REPO/'build/DerivedData/Build/Products/Debug/Zeus.app/Contents/MacOS/zeus-mcp'
        config = pane.root/'mcp.json'
        config.write_text(json.dumps({'mcpServers': {'zeus': {'command': str(bridge), 'args': ['--agent', 'claude', '--socket', str(pane.root/'bridge.sock')]}}}))
        with (OUT/'host.log').open('w') as log:
            process = subprocess.Popen([str(host), str(pane.root), pane.tmux, '--rf1'], env=pane.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            control = HostControl(process); control.read()
            pane.start(Model, lambda base: [pane.cli, '--mcp-config', str(config), '--model', 'claude-haiku-4-5', '--permission-mode', 'manual', '--allowedTools', 'mcp__zeus__*', 'Write'],
                       lambda base: {'ANTHROPIC_API_KEY': 'rf1-local-fixture', 'ANTHROPIC_BASE_URL': base})
            pane.onboard()
            eventually(lambda: control.call('state')['sessions'] == 1, 'bridge connects', timeout=45)
            pane.send('Begin the isolated reflection fixture.')
            eventually(lambda: 'RF1 fixture complete' in pane.plain(), 'native warmup ends', timeout=45)
            control.call('reflect')
            state = eventually(lambda: s if (s := control.call('state'))['rules'] and s['deliveries'] and s['deliveries'][0]['acked'] else None,
                               'native notes writes, valid cross-day rule and ack', timeout=75)
            assert pane.tm('display-message', '-p', '-t', 'pc1', '#{pane_width}x#{pane_height}').strip() == '120x40'
            text = state['reflectionTexts'][0]
            assert len(text.encode()) <= 10240 and 'Sequences' in text and 'Notes/patterns.md' in text, text
            assert len(state['rules']) == 1 and state['rules'][0]['status'] == 'active', state
            assert state['deliveries'][0]['attempts'] == 1 and state['deliveries'][0]['pointer'] is True, state
            assert state['receipts'][0]['payload']['value']['text'] == text, state
            notes = {name: (pane.project/'Notes'/name).read_text() for name in ['about-you.md', 'patterns.md']}
            assert all('14 October:' in value for value in notes.values()), notes
            results = [block for body in Model.requests for message in body.get('messages', []) if isinstance(message.get('content'), list)
                       for block in message['content'] if block.get('type') == 'tool_result']
            assert not any(block.get('is_error') for block in results), results
            proof = scrub_paths({'agent': pane.version, 'tools': steps, 'evidence': cited, 'notes': notes, 'state': state,
                'isolation': 'private tmux, disposable HOME/config, localhost scripted model, injected test key',
                'pane': '120x40; short pointer fetched by id', 'fetched': fetched,
                'scope': 'Real CLI/tool integration; scripted local model, not evidence of model reasoning quality'}, {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'})
            (OUT/'proof.json').write_text(json.dumps(proof, indent=2)+'\n')
            (OUT/'digest.txt').write_text(text+'\n')
            if args.record:
                target = REPO/'TestFixtures/live/rf1'; target.mkdir(parents=True, exist_ok=True)
                (target/'reflection.json').write_text(json.dumps(proof, indent=2)+'\n')
            print(json.dumps({'passed': True, 'agent': pane.version, 'tools': steps, 'rule_accepted': True}))
    finally:
        results = [block for body in Model.requests for message in body.get('messages', []) if isinstance(message.get('content'), list)
                   for block in message['content'] if block.get('type') == 'tool_result']
        (OUT/'tool-results.json').write_text(json.dumps(scrub_paths(results, {str(pane.root): '/FIXTURE', str(REPO): '<worktree>'}), indent=2)+'\n')
        if process: stop_host(process)
        pane.close()

if __name__ == '__main__': main()
