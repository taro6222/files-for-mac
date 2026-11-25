#!/usr/bin/env python3
"""Assess the existing 20-process optimized warm-cache 10k benchmark; never rewrite raw results."""
import argparse
import json
import math
from pathlib import Path
import re
import sys


def assess(report, expected_source, expected_architecture):
    if report.get('sourceBaseSHA') != expected_source or report.get('architecture') != expected_architecture:
        raise ValueError('Benchmark source or architecture differs from the requested run')
    if not re.fullmatch(r'[0-9a-f]{64}', report.get('binarySHA256', '')):
        raise ValueError('Missing benchmark executable SHA-256')
    samples = report.get('samples', {}).get('10000', [])
    if len(samples) != 20:
        raise ValueError('Expected exactly 20 fresh-process 10,000-item samples')
    computed = {}
    for metric in ('firstDisplaySeconds', 'modelLoadFinishedSeconds', 'listingSeconds'):
        values = [sample.get(metric) for sample in samples]
        if any(isinstance(value, bool) or not isinstance(value, (float, int))
               or not math.isfinite(value) or value < 0 for value in values):
            raise ValueError(f'Missing or invalid timing: {metric}')
        values.sort()
        computed[metric] = {'max': values[-1], 'p95': values[math.ceil(len(values) * .95) - 1]}
        if report.get('summary', {}).get('10000', {}).get(metric) != computed[metric]:
            raise ValueError(f'Recorded summary differs from raw samples: {metric}')
    checks = {'first100DisplayedWithin500msP95': computed['firstDisplaySeconds']['p95'] <= .5,
              'modelEnumerationWithin2SecondsP95': computed['modelLoadFinishedSeconds']['p95'] <= 2}
    return {'state': 'passed' if all(checks.values()) else 'failed', 'checks': checks,
            'sourceBaseSHA': expected_source, 'architecture': expected_architecture,
            'binarySHA256': report['binarySHA256'], 'samples': len(samples), 'computed': computed,
            'limits': ['Optimized QA executable with warm OS caches; not a signed installed distribution.',
                       'AppKit display completion does not measure compositor frames or actual keyboard input.',
                       'Cold startup, 100k acceptance, idle memory, and eight-hour stability remain separate gates.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--expected-source', required=True)
    parser.add_argument('--expected-architecture', choices=['arm64', 'x86_64'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if (args.report.resolve() == args.output.resolve()
            or (args.report.exists() and args.output.exists() and args.report.samefile(args.output))):
        print('Assessment output must not replace the raw benchmark report', file=sys.stderr)
        return 2
    try:
        result = assess(json.loads(args.report.read_text()), args.expected_source, args.expected_architecture)
        status = 0 if result['state'] == 'passed' else 1
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        result, status = {'state': 'invalid-evidence', 'error': str(error)}, 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
