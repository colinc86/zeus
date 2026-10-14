import importlib.util, pathlib, unittest
spec=importlib.util.spec_from_file_location('batch',pathlib.Path(__file__).with_name('scroll-perf.py'))
batch=importlib.util.module_from_spec(spec);spec.loader.exec_module(batch)

class BatchTests(unittest.TestCase):
    def record(self,value,worst=16,valid=True):
        return dict(configuration='baseline',summary=dict(completed=valid,surface_valid=True,traversal_valid=True,target_updates=1,
            hitch_ms_per_s=value,worst_hitch_ms=worst,gate_pass=value<5 and worst<=16.667))
    def test_median_range_keeps_outliers_and_worst_peak(self):
        rows=[self.record(n,worst=100 if n==99 else 16) for n in [1,2,3,4,99]]
        result=batch.aggregate(rows,['baseline'],5)['baseline']
        self.assertEqual(result['hitch_ms_per_s']['median'],3)
        self.assertEqual(result['hitch_ms_per_s']['minimum'],1)
        self.assertEqual(result['hitch_ms_per_s']['maximum'],99)
        self.assertEqual(result['worst_hitch_ms']['maximum'],100)
        self.assertEqual(result['gate_passes'],4)
        self.assertFalse(result['all_pass'])
    def test_invalid_capture_cannot_complete_n(self):
        result=batch.aggregate([self.record(1),self.record(0,valid=False)],['baseline'],2)['baseline']
        self.assertEqual(result['valid'],1);self.assertFalse(result['all_pass'])
    def test_every_round_contains_each_configuration_once(self):
        plan=batch.plan(batch.CONFIGURATIONS,5,13)
        self.assertEqual(len(plan),30)
        self.assertEqual(plan,batch.plan(batch.CONFIGURATIONS,5,13))
        for round_number in range(1,6):
            self.assertCountEqual([p['configuration'] for p in plan if p['round']==round_number],batch.CONFIGURATIONS)

if __name__=='__main__':unittest.main()
