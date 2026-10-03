#!/usr/bin/env python3
"""把翻译好的 JSON（{英文模板: 译文}）生成 Sources/DockTouchBar/Translations+<语言>.swift。
用法：tools/l10n/generate.py <JSON 所在目录>   （目录里是 zh-Hant.json、ja.json … ）"""
import json, os, sys

LANGS = {'zh-Hant': 'zhHant', 'ja': 'ja', 'ko': 'ko', 'fr': 'fr', 'de': 'de', 'es': 'es',
         'pt': 'pt', 'ru': 'ru', 'it': 'it', 'tr': 'tr'}

def lit(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'

def main(src):
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
    for code, name in LANGS.items():
        path = os.path.join(src, code + '.json')
        if not os.path.exists(path):
            print('missing', path)
            continue
        table = json.load(open(path, encoding='utf-8'))
        lines = ['import Foundation', '', '// 由 tools/l10n/generate.py 生成，不要手改；改译文请改 JSON 后重新生成。',
                 'extension Translations {', '    static let %s: [String: String] = [' % name]
        for key, value in table.items():
            lines.append('        %s: %s,' % (lit(key), lit(value)))
        lines += ['    ]', '}', '']
        out = os.path.join(root, 'Sources', 'DockTouchBar', 'Translations+%s.swift' % code)
        open(out, 'w', encoding='utf-8').write('\n'.join(lines))
        print('wrote', os.path.normpath(out), len(table))

if __name__ == '__main__':
    main(sys.argv[1])
