import copy
import importlib.util
from pathlib import Path
import unittest
import json
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('baseline', Path(__file__).parents[2] / 'scripts/check-performance-baseline.py')
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


def report():
    values = {'firstDisplaySeconds': .5, 'modelLoadFinishedSeconds': 2, 'listingSeconds': 2.5}
    return {'sourceBaseSHA': 'a' * 40, 'architecture': 'arm64', 'binarySHA256': 'b' * 64,
            'samples': {'10000': [dict(values) for _ in range(20)]},
            'summary': {'10000': {k: {'max': v, 'p95': v} for k, v in values.items()}}}


class BaselineEvidenceTests(unittest.TestCase):
    def assess(self, value):
        return baseline.assess(value, 'a' * 40, 'arm64')

    def test_accepts_exact_boundaries_without_claiming_other_release_gates(self):
        result = self.assess(report())
        self.assertEqual(result['state'], 'passed')
        self.assertEqual(result['computed']['listingSeconds']['p95'], 2.5)
        self.assertTrue(result['limits'])

    def test_two_slow_samples_fail_p95_even_when_eighteen_are_fast(self):
        value = report()
        for sample in value['samples']['10000'][-2:]:
            sample['modelLoadFinishedSeconds'] = 2.01
        value['summary']['10000']['modelLoadFinishedSeconds'] = {'max': 2.01, 'p95': 2.01}
        self.assertFalse(self.assess(value)['checks']['modelEnumerationWithin2SecondsP95'])
        self.assertEqual(self.assess(value)['state'], 'failed')

    def test_modified_summary_cannot_hide_slow_raw_samples(self):
        value = report()
        value['samples']['10000'][-2]['modelLoadFinishedSeconds'] = 9
        value['samples']['10000'][-1]['modelLoadFinishedSeconds'] = 9
        with self.assertRaisesRegex(ValueError, 'summary differs'):
            self.assess(value)

    def test_missing_or_nonfinite_samples_are_invalid_evidence(self):
        for bad in [None, float('nan'), float('inf'), True, -1]:
            value = report()
            value['samples']['10000'][0]['firstDisplaySeconds'] = bad
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.assess(value)
        value = report()
        value['samples']['10000'].pop()
        with self.assertRaisesRegex(ValueError, '20 fresh-process'):
            self.assess(value)

    def test_different_source_architecture_or_missing_binary_digest_is_invalid(self):
        for key, bad in [('sourceBaseSHA', 'c' * 40), ('architecture', 'x86_64'), ('binarySHA256', '')]:
            value = copy.deepcopy(report())
            value[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.assess(value)


    def test_cli_preserves_raw_report_when_output_is_same_file_or_hardlink(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'raw.json'
            source.write_text(json.dumps(report()))
            original = source.read_bytes()
            alias = source.with_name('alias.json')
            alias.hardlink_to(source)
            for output in [source, alias]:
                result = subprocess.run([sys.executable, str(Path(baseline.__file__)), str(source),
                    '--expected-source', 'a' * 40, '--expected-architecture', 'arm64', '--output', str(output)],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(source.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
