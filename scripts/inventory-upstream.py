#!/usr/bin/env python3
"""Read pinned public sources; emit review inventories (never implies parity)."""
import argparse
import concurrent.futures
import csv
import json
from pathlib import Path
import re
import urllib.request

SHA = '99951c66928c4da714da8b1dd46039421182cbab'
ROOT = Path(__file__).resolve().parents[1] / 'docs/reference'
def read(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode('utf-8-sig')
def source(path):
    return path, read(f'https://raw.githubusercontent.com/files-community/Files/{SHA}/{path}')
def write(name, fields, rows):
    with (ROOT / name).open('w') as f:
        writer = csv.writer(f, lineterminator='\n'); writer.writerow(fields); writer.writerows(rows)

def check_inventory(name, fields, expected):
    with (ROOT / name).open(newline='', encoding='utf-8') as stream:
        actual = [tuple(row[field] for field in fields) for row in csv.DictReader(stream)]
    expected = [tuple(str(value) for value in row) for row in expected]
    if sorted(actual) != sorted(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        raise SystemExit(f'{name}: expected {len(expected)} rows, found {len(actual)}; '
                         f'missing={missing}; unexpected={extra}')
    print(f'{name}: {len(actual)} rows match')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='compare source-derived fields without writing inventories')
    parser.add_argument('--source-tree', type=Path, help='local copy of the pinned upstream tree for offline --check')
    arguments = parser.parse_args()
    checkout = arguments.source_tree
    if checkout is not None and not arguments.check:
        parser.error('--source-tree requires --check')
    if checkout is None:
        tree = json.loads(read(f'https://api.github.com/repos/files-community/Files/git/trees/{SHA}?recursive=1'))
        if tree.get('truncated'):
            raise SystemExit('Incomplete Git tree')
        paths = [item['path'] for item in tree['tree'] if item['type'] == 'blob']
    else:
        if not (checkout / 'src/Files.App').is_dir():
            parser.error('--source-tree must contain src/Files.App')
        paths = [p.relative_to(checkout).as_posix() for p in (checkout / 'src').rglob('*') if p.is_file()]
    selected = [p for p in paths if p.endswith('.cs') and (p.startswith('src/Files.App/Actions/') or p.startswith('src/Files.App/Services/Settings/'))]
    if checkout is None:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            sources = list(pool.map(source, selected))
    else:
        sources = [(path, (checkout / path).read_text(encoding='utf-8-sig')) for path in selected]
    commands, settings = [], []
    for path, text in sorted(sources):
        evidence = f'https://github.com/files-community/Files/blob/{SHA}/{path}'
        if '/Actions/' in path:
            # Files source generator uses GeneratedRichCommand on a class.
            for match in re.finditer(r'\[GeneratedRichCommand[^\]]*\][\s\S]*?\bclass\s+(\w+)', text):
                name = match.group(1).removesuffix('Action')
                line = text[:match.start()].count('\n') + 1
                commands.append([name,path,SHA,line,'','V','planned','awaiting-behavior-review',evidence+f'#L{line}'])
        else:
            for match in re.finditer(r'public\s+([\w<>?, .]+)\s+(\w+)\s*\{\s*get\s*=>\s*Get(?:<[^>]+>)?\(([^;]*)\);', text):
                line = text[:match.start()].count('\n') + 1
                settings.append([match.group(2),match.group(1),match.group(3),path,SHA,line,'V','awaiting-behavior-review',evidence+f'#L{line}'])
    source_files = [[p, SHA, 'actions-or-settings'] for p in sorted(selected)]
    if arguments.check:
        check_inventory('COMMANDS.csv', ('source_id', 'source_path', 'source_sha', 'line'),
                        (row[:4] for row in commands))
        check_inventory('SETTINGS.csv', ('source_key', 'type', 'default_expression', 'source_path', 'source_sha', 'line'),
                        (row[:6] for row in settings))
        check_inventory('SOURCE_FILES.csv', ('path', 'sha', 'scope'), source_files)
        check_inventory('SCREENS.csv', ('source_path', 'source_sha'),
                        ((p, SHA) for p in paths if p.startswith('src/Files.App/Views/') and p.endswith('.xaml')))
        return
    ROOT.mkdir(parents=True, exist_ok=True)
    write('COMMANDS.csv',['source_id','source_path','source_sha','line','mac_command_id','classification','milestone','status','evidence'],commands)
    write('SETTINGS.csv',['source_key','type','default_expression','source_path','source_sha','line','classification','status','evidence'],settings)
    write('SOURCE_FILES.csv',['path','sha','scope'],source_files)
    print(f'{len(commands)} attributed command candidates; {len(settings)} simple settings properties; {len(selected)} source files')
    print('Parameterized/generated commands and complex properties still require manual review.')
if __name__ == '__main__': main()
