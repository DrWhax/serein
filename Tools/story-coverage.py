#!/usr/bin/env python3
"""Storybook coverage: stories with a reference capture in the SignalUI test target, per
component (stories spliced for out-of-scope rows count under their original id).

  Tools/story-coverage.py [prefix]      e.g. components-conversation-
"""
import glob, json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
index = json.load(open(os.path.join(root, '.cache/storybook-desktop/storybook-static/index.json')))['entries']
ids = sorted(k for k, v in index.items() if v.get('type') == 'story')
refs = {re.sub(r'\.(light|dark)\.png$', '', os.path.basename(f)).replace('-without-payments', '')
        for f in glob.glob(os.path.join(root, 'Packages/SignalUI/Tests/SignalUITests/References/*.png'))}
prefix = sys.argv[1] if len(sys.argv) > 1 else ''
comp = {}
for i in ids:
    c = i.split('--')[0]
    comp.setdefault(c, [0, 0, []])
    comp[c][1] += 1
    if i in refs: comp[c][0] += 1
    else: comp[c][2].append(i.split('--')[1])
print('stories', len(ids), 'covered', sum(v[0] for v in comp.values()))
for c, (a, b, missing) in sorted(comp.items()):
    if c.startswith(prefix) and a < b:
        print(f'{a:3}/{b:<3} {c}: {" ".join(missing)}')
