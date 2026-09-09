#!/usr/bin/env python3
"""Read pinned public sources; emit review inventories (never implies parity)."""
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

def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    tree = json.loads(read(f'https://api.github.com/repos/files-community/Files/git/trees/{SHA}?recursive=1'))
    assert not tree.get('truncated'), 'Incomplete Git tree'
    paths = [item['path'] for item in tree['tree']]
    selected = [p for p in paths if p.endswith('.cs') and (p.startswith('src/Files.App/Actions/') or p.startswith('src/Files.App/Services/Settings/'))]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        sources = list(pool.map(source, selected))
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
    write('COMMANDS.csv',['source_id','source_path','source_sha','line','mac_command_id','classification','milestone','status','evidence'],commands)
    write('SETTINGS.csv',['source_key','type','default_expression','source_path','source_sha','line','classification','status','evidence'],settings)
    write('SOURCE_FILES.csv',['path','sha','scope'],[[p,SHA,'actions-or-settings'] for p in selected])
    print(f'{len(commands)} attributed command candidates; {len(settings)} simple settings properties; {len(selected)} source files')
    print('Parameterized/generated commands and complex properties still require manual review.')
if __name__ == '__main__': main()
