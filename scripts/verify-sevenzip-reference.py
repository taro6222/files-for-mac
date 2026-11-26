#!/usr/bin/env python3
"""Run the real provider/7-Zip interoperability gate and bounded advanced-format probes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import signal
import subprocess
import tempfile
import sevenzip_reference as reference

def advanced_probe(binary, root):
    password = 'QA-344-한글-🔑'
    source = root / 'payload-한글.bin'
    payload = random.Random(344).randbytes(256 * 1024)
    source.write_bytes(payload)
    def run(arguments, secret=None):
        result = subprocess.run([str(binary), *arguments], cwd=root,
                                input=((secret + '\n' + secret + '\n').encode() if secret else b''),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        if secret and (secret.encode() in result.stdout or any(secret in arg for arg in arguments)):
            raise RuntimeError('Reference password appeared in arguments or output')
        return result.returncode, result.stdout.decode(errors='replace')
    checks = {}
    status, _ = run(['a', '-t7z', '-m0=LZMA2', '-md=64k', '-mfb=32', '-mmt=2', '-mx=5', '-mhe=on',
                     '-p', '-v64k', '-y', '-sccUTF-8', 'options.7z', source.name], password)
    parts = sorted(root.glob('options.7z.*'))
    checks['encryptedSplitCreation'] = status == 0 and len(parts) > 1 and all(p.name == f'options.7z.{i:03d}' for i, p in enumerate(parts, 1))
    if not checks['encryptedSplitCreation']: raise RuntimeError('7z option combination did not create split volumes')
    original = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in parts}
    status, text = run(['l', '-slt', '-sccUTF-8', parts[0].name])
    checks['encryptedHeadersHideFileName'] = status != 0 and source.name not in text
    status, text = run(['l', '-slt', '-sccUTF-8', parts[0].name], password)
    methods = [line for line in text.splitlines() if line.startswith('Method = ')]
    checks['requestedDictionaryObserved'] = status == 0 and any('LZMA2:16' in line for line in methods)
    status, _ = run(['x', '-y', '-sccUTF-8', '-oextracted', parts[0].name], password)
    checks['unicodePasswordRoundTrip'] = status == 0 and (root / 'extracted' / source.name).read_bytes() == payload
    status, _ = run(['t', '-sccUTF-8', parts[0].name], 'wrong-password')
    checks['wrongPasswordRejected'] = status != 0
    held = root / 'held-volume'; missing = parts[1]; missing.rename(held)
    try:
        status, _ = run(['t', '-sccUTF-8', parts[0].name], password)
        checks['missingVolumeRejected'] = status != 0
    finally:
        if missing.exists(): raise RuntimeError('Missing volume destination unexpectedly appeared')
        held.rename(missing)
    status, _ = run(['t', '-sccUTF-8', parts[0].name], password)
    checks['restoredVolumesVerify'] = status == 0
    checks['archivePartsPreserved'] = original == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in parts}
    checks['sourcePreserved'] = source.read_bytes() == payload
    return {'checks': checks, 'splitVolumes': len(parts), 'methodLines': methods,
            'requestedOptions': {'dictionaryBytes': 65536, 'wordSize': 32, 'threads': 2, 'level': 5,
                                 'headerEncryption': True, 'splitBytes': 65536},
            'scope': 'reference feasibility only; not product backend acceptance or a measurement of actual thread use'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = args.output.absolute(); output.mkdir(parents=True, exist_ok=False)
    result = {'passed': False, 'referenceVersion': reference.VERSION}
    try:
        binary = reference.acquire(repo / 'build/sevenzip-reference' / reference.VERSION / platform.machine(), platform.machine())
        (output / 'reference-provenance.json').write_bytes((binary.parent / 'manifest.json').read_bytes())
        env = dict(os.environ, FILES_TEST_SEVENZIP_REFERENCE=str(binary), FILES_TEST_SEVENZIP_REPORT=str(output / 'interoperability.json'))
        with (output / 'run.log').open('wb') as log:
            with subprocess.Popen(['swift', 'test', '--skip-build', '--disable-xctest', '--no-parallel', '--filter',
                                   'archiveIndependentSevenZipAESInteroperability'], cwd=repo, env=env,
                                  stdout=log, stderr=subprocess.STDOUT, start_new_session=True) as process:
                try: status = process.wait(timeout=90)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
                    raise RuntimeError('Independent interoperability gate exceeded 90 seconds')
        text = (output / 'run.log').read_text(errors='replace')
        evidence = json.loads((output / 'interoperability.json').read_text())
        result['providerInteroperability'] = evidence
        provider_passed = (status == 0 and re.search(r'✔ Test archiveIndependentSevenZipAESInteroperability\(\) passed', text)
                           and len(evidence['checks']) == 15 and all(evidence['checks'].values()))
        if not provider_passed: raise RuntimeError('Provider interoperability checks failed or did not execute')
        with tempfile.TemporaryDirectory(prefix='sevenzip-options-', dir=output) as temporary:
            result['advancedReferenceProbe'] = advanced_probe(binary, Path(temporary))
        result['passed'] = all(result['advancedReferenceProbe']['checks'].values())
    except Exception as error: result['error'] = str(error)
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1

if __name__ == '__main__': raise SystemExit(main())
