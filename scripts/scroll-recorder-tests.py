"""Check recorder staging ownership without recording a trace or opening an app."""
import ast, os, pathlib, subprocess, tempfile, unittest

source = pathlib.Path(__file__).with_name('scroll-capture.py').read_text()
function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == 'remember_staging')
module = ast.Module(body=[function], type_ignores=[])

class RecorderStagingTests(unittest.TestCase):
    def test_only_recorder_open_staging_is_remembered(self):
        build = pathlib.Path(__file__).resolve().parent.parent/'build'
        with tempfile.TemporaryDirectory(dir=build, prefix='recorder-test-') as temporary:
            root = pathlib.Path(temporary)
            owned = root/'recorder'; owned.mkdir()
            unrelated = root/'unrelated'; unrelated.mkdir()
            paths = [owned/'instruments-owned.ktrace', owned/'other.txt', unrelated/'instruments-other.ktrace']
            handles = [p.open('w') for p in paths]
            try:
                namespace = dict(pathlib=pathlib, subprocess=subprocess, tempfile=tempfile, os=os,
                                 recorder_temporary=owned, owned_staging={})
                exec(compile(module, '<staging-function>', 'exec'), namespace)
                recorder = type('Recorder', (), dict(pid=os.getpid()))()
                namespace['remember_staging'](recorder)
                self.assertEqual(namespace['owned_staging'], {paths[0]: paths[0].stat().st_ino})
                # A second processing-phase check is idempotent and catches late-opened files.
                late = owned/'instruments-late.ktrace'
                with late.open('w'):
                    namespace['remember_staging'](recorder)
                    self.assertEqual(set(namespace['owned_staging']), {paths[0], late})
            finally:
                for handle in handles: handle.close()

if __name__ == '__main__': unittest.main()
