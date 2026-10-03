#!/usr/bin/env python3
"""从源码里的 L10n.tr("中文", "English") 调用提取待翻译的文字，输出 JSON：[{"en": 模板, "zh": 中文模板}, ...]
模板里的 \\(表达式) 记成 {0}、{1}…，和运行时 LText 的规则一致。用法：tools/l10n/extract.py > strings.json"""
import glob, json, sys

ESC = {'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0', 'r': '\r'}

def parse_literal(src, i):
    """src[i] 必须是引号。返回 (模板, 下一个位置)。"""
    assert src[i] == '"', src[i:i+40]
    i += 1
    out, n = [], 0
    while src[i] != '"':
        c = src[i]
        if c == '\\':
            d = src[i + 1]
            if d == '(':
                depth, j = 1, i + 2
                while depth:
                    if src[j] == '(':
                        depth += 1
                    elif src[j] == ')':
                        depth -= 1
                    j += 1
                out.append('{%d}' % n)
                n += 1
                i = j
                continue
            if d == 'u':  # \u{XXXX}
                j = src.index('}', i)
                out.append(chr(int(src[i + 3:j], 16)))
                i = j + 1
                continue
            out.append(ESC[d])
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out), i + 1

def skip(src, i):
    while src[i] in ' \n\t,':
        i += 1
    return i

def main(root):
    entries = {}
    for path in sorted(glob.glob(root + '/Sources/DockTouchBar/*.swift')):
        src = open(path, encoding='utf-8').read()
        pos = 0
        while True:
            pos = src.find('L10n.tr(', pos)
            if pos < 0:
                break
            pos += len('L10n.tr(')
            zh, pos = parse_literal(src, skip(src, pos))
            en, pos = parse_literal(src, skip(src, pos))
            entries.setdefault(en, zh)
    return [{'en': en, 'zh': zh} for en, zh in entries.items()]

if __name__ == '__main__':
    json.dump(main(sys.argv[1] if len(sys.argv) > 1 else '.'), sys.stdout, ensure_ascii=False, indent=1)
