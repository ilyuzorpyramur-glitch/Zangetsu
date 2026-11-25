#!/usr/bin/env python3
"""Append l10n keys to app_en.arb (template, with metadata) and app_ru.arb.

Text-based insertion before the closing brace so the diff stays minimal and the
existing formatting of both files is untouched.

Usage: python3 tool/add_l10n.py keys.tsv
keys.tsv rows: key<TAB>en<TAB>ru<TAB>placeholders(optional: name:type,name2:type)
"""
import json
import sys

EN = 'lib/l10n/app_en.arb'
RU = 'lib/l10n/app_ru.arb'


def existing(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def append(path, block):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    idx = text.rstrip().rfind('}')
    head = text[:idx].rstrip()
    if not head.endswith(','):
        head += ','
    block = block.rstrip().rstrip(',')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(head + '\n' + block + '\n}\n')


def main():
    rows = []
    with open(sys.argv[1], encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.strip() or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 3:
                raise SystemExit(f'bad row: {line!r}')
            key, en, ru = parts[0], parts[1], parts[2]
            ph = parts[3] if len(parts) > 3 else ''
            rows.append((key, en, ru, ph))

    have_en = existing(EN)
    have_ru = existing(RU)
    en_lines, ru_lines = [], []
    for key, en, ru, ph in rows:
        if key in have_en:
            print(f'! {key} already exists; skipped')
            continue
        en_lines.append(f'  {json.dumps(key)}: {json.dumps(en, ensure_ascii=False)},')
        if ph:
            spec = {}
            for item in ph.split(','):
                name, _, typ = item.partition(':')
                spec[name.strip()] = {'type': typ.strip() or 'String'}
            en_lines.append(
                f'  {json.dumps("@" + key)}: {json.dumps({"placeholders": spec}, ensure_ascii=False)},'
            )
        if key in have_ru:
            print(f'! {key} already in ru; ru skipped')
        else:
            ru_lines.append(f'  {json.dumps(key)}: {json.dumps(ru, ensure_ascii=False)},')
    if en_lines:
        append(EN, '\n'.join(en_lines) + '\n')
    if ru_lines:
        append(RU, '\n'.join(ru_lines) + '\n')
    print(f'added {len(en_lines and rows)} rows; en={len(en_lines)} ru={len(ru_lines)}')


if __name__ == '__main__':
    main()
