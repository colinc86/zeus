"""Exercise the scroll gate without launching Instruments or touching the user's app."""
import contextlib, importlib.util, io, json, pathlib, tempfile, unittest

spec = importlib.util.spec_from_file_location('summary', pathlib.Path(__file__).with_name('scroll-trace-summary.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)

class ScrollGateTests(unittest.TestCase):
    def result(self, *, endpoints=(28000, 0), updates=True, completed=True, visible=True, duration=16666666):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root/'scroll-result.json').write_text(json.dumps(dict(endpoints=endpoints, duration_s=9, completed=completed,
                surface_valid=visible, visibility='cardOrdered=true')))
            (root/'toc.xml').write_text('<trace-toc><run><info><summary><duration>10</duration></summary><target><process pid="7"/></target></info>'
                '<data><table schema="hitches"/><table schema="hitches-updates"/></data></run></trace-toc>')
            row = '<row><process id="p"><pid id="pid">7</pid></process><start-time>1000000000</start-time><duration>%d</duration><string>Render</string></row>' % duration
            update = '<row><process ref="p"/></row>' if updates else ''
            (root/'hitches.xml').write_text('<root><node xpath="table[1]"><schema name="hitches"/>'+row+'</node><node xpath="table[2]">'+update+'</node></root>')
            with contextlib.redirect_stdout(io.StringIO()): return summary.summarize(root)
    def test_complete_visible_traversal_can_pass(self): self.assertTrue(self.result()['gate_pass'])
    def test_empty_native_document_cannot_pass(self): self.assertFalse(self.result(endpoints=(0, 0))['gate_pass'])
    def test_no_target_updates_cannot_pass(self): self.assertFalse(self.result(updates=False)['gate_pass'])
    def test_incomplete_or_hidden_surface_cannot_pass(self):
        self.assertFalse(self.result(completed=False)['gate_pass'])
        self.assertFalse(self.result(visible=False)['gate_pass'])
    def test_peak_over_two_frames_cannot_pass(self): self.assertFalse(self.result(duration=33333333)['gate_pass'])

if __name__ == '__main__': unittest.main()
