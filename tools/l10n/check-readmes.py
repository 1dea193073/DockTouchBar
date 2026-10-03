#!/usr/bin/env python3
"""检查各语言 README 的结构和 README.md 一致：行数相近、代码块数、所有链接目标/图片、语言切换块、标题数。"""
import glob, re, sys
base = open('README.md', encoding='utf-8').read()
def facts(t):
    return dict(fences=t.count('```'), urls=sorted(u for m in re.findall(r'\]\(([^)\s]+)\)|href="([^"]+)"|src="([^"]+)"', t) for u in m if u and not u.startswith('#') and 'img.shields.io' not in u),
                headings=len(re.findall(r'^#{1,6} ', t, re.M)), rows=len(re.findall(r'^\|', t, re.M)), lines=t.count('\n'))
b = facts(base)
bad = 0
for f in sorted(glob.glob('README.*.md')):
    if f == 'README.zh-CN.md': continue
    t = open(f, encoding='utf-8').read()
    x = facts(t)
    problems = [k for k in ('fences', 'urls', 'headings', 'rows') if x[k] != b[k]]
    if abs(x['lines'] - b['lines']) > b['lines'] * 0.15: problems.append('lines %d vs %d' % (x['lines'], b['lines']))
    # 代码块里的命令必须原样（只允许注释被翻译）；页内锚点必须对得上本文件的标题
    strip = lambda block: [l.split('#')[0].rstrip() if not l.lstrip().startswith('```') else l for l in block.split('\n')]
    cb = [strip(c) for c in re.findall(r'```bash.*?```', base, re.S)]
    cx = [strip(c) for c in re.findall(r'```bash.*?```', t, re.S)]
    if cb != cx: problems.append('code block commands differ')
    slugs = {re.sub(r'[^\w\- ]', '', h.lower()).strip().replace(' ', '-') for h in re.findall(r'^#{1,6} (.+)$', t, re.M)}
    broken = [a for a in re.findall(r'\]\(#([^)]+)\)', t) if a not in slugs]
    if broken: problems.append('broken anchors %s' % broken)
    print(('FAIL ' if problems else 'PASS ') + f, problems or '')
    bad += bool(problems)
sys.exit(1 if bad else 0)
