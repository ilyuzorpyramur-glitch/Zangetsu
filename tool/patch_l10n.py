#!/usr/bin/env python3
"""Apply literal→expression replacements at exact file:line sites.

Usage: python3 tool/patch_l10n.py patches.tsv
Rows: path<TAB>line<TAB>old literal text<TAB>new expression
The old text is matched as a plain substring of that one line (with its
surrounding quotes), so a wrong line number fails loudly instead of silently
patching the wrong site.
"""
import sys

by_file = {}
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line.strip() or line.startswith('#'):
            continue
        path, lineno, old, new = line.split('\t')
        by_file.setdefault(path, []).append((int(lineno), old, new))

failures = []
for path, items in by_file.items():
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    for lineno, old, new in items:
        idx = lineno - 1
        if idx >= len(lines):
            failures.append(f'{path}:{lineno} line out of range')
            continue
        if old not in lines[idx]:
            failures.append(f'{path}:{lineno} not found: {old!r}')
            continue
        lines[idx] = lines[idx].replace(old, new, 1)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    print(f'patched {path}: {len(items)} site(s)')

for f in failures:
    print('FAIL', f)
sys.exit(1 if failures else 0)
