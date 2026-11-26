#!/usr/bin/env python3
"""Create a fixed local bare remote for UI clone/content/commit verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess


def create(output):
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    remote = output / 'remote.git'
    source.mkdir()
    files = {'README.md': 'Files Git UI fixture\n', '한글-é.txt': 'Unicode Git fixture\n', '.gitignore': 'ignored/\n'}
    files.update({f'tracked/{index:02d}.txt': f'Fixed tracked payload {index}\n' for index in range(32)})
    for name, value in files.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value.encode('utf-8'))
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0',
                       GIT_AUTHOR_DATE='2020-01-01T00:00:00+00:00', GIT_COMMITTER_DATE='2020-01-01T00:00:00+00:00')

    def git(arguments):
        command = ['/usr/bin/git', '-c', 'user.name=Files UI QA', '-c', 'user.email=files-ui-qa@example.invalid',
                   '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', '-c', 'core.autocrlf=false'] + arguments
        with subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise
            with (output / 'setup.log').open('ab') as log:
                log.write(stdout + stderr)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
            return stdout.decode('utf-8').strip()

    git(['-C', str(source), 'init', '--initial-branch=main', '--object-format=sha1'])
    git(['-C', str(source), 'add', '--', '.'])
    git(['-C', str(source), 'commit', '-m', 'Fixed UI clone fixture'])
    head = git(['-C', str(source), 'rev-parse', 'HEAD'])
    git(['clone', '--bare', '--', source.as_uri(), str(remote)])
    assert git(['-C', str(remote), 'rev-parse', 'refs/heads/main']) == head
    result = dict(version=1, remote=str(remote), commit=head, branch='main', files=files,
                  filesSHA256={name: hashlib.sha256(value.encode('utf-8')).hexdigest() for name, value in files.items()})
    manifest = output / 'manifest.json'
    manifest.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(create(args.output.resolve()))


if __name__ == '__main__':
    main()
