#!/usr/bin/env python3
"""Splice the Settings sidebar's "Donate to Signal" and "Backups" rows out of Preferences
captures (SignalSafe has neither), finding them in each capture's .dom.json.

  Tools/splice-preferences.py <story-id-suffix>...   e.g. calls data-usage

Writes Packages/SignalUI/Tests/SignalUITests/References/components-preferences--<s>-without-donations.{light,dark}.{png,json}.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REFS = os.path.join(ROOT, ".cache/storybook-refs")
OUT = os.path.join(ROOT, "Packages/SignalUI/Tests/SignalUITests/References")
LABELS = {"Donate to Signal", "Backups"}

def rows(dom):
    found = []
    def walk(n):
        if n.get("tag") == "button" and "rounded-xl" in (n.get("cls") or ""):
            texts = [c.get("text") for c in n.get("children", []) if c.get("text")]
            if any(t in LABELS for t in texts):
                x, y, w, h = n["rect"]
                # my-0.5 collapses with its neighbours: one 2px margin goes with the row.
                found.append((y - 2, y + h, x + w + 11))   # and the sidebar's 11px inset
        for c in n.get("children", []):
            walk(c)
    for n in dom:
        walk(n)
    return sorted(found, reverse=True)   # bottom first, so earlier cuts don't move later ones

for story in sys.argv[1:]:
    for theme in ("light", "dark"):
        base = os.path.join(REFS, f"components-preferences--{story}.{theme}")
        dom = json.load(open(base + ".dom.json"))
        cur = base
        tmp = tempfile.mkdtemp()
        cuts = rows(dom)
        for i, (top, bottom, right) in enumerate(cuts):
            nxt = os.path.join(OUT, f"components-preferences--{story}-without-donations.{theme}") if i == len(cuts) - 1 else os.path.join(tmp, f"s{i}")
            subprocess.run([sys.executable, os.path.join(ROOT, "Tools/splice-reference.py"), cur, nxt, str(top), str(bottom), "0", str(right)], check=True,
                           stdout=subprocess.DEVNULL)
            cur = nxt
        print(story, theme, len(cuts), "rows cut")
