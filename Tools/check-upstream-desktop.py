#!/usr/bin/env python3
"""Open an issue to review a new Signal-Desktop release for features Serein should port.

Tools/upstream-desktop.txt holds the Desktop tag Serein has been reviewed up to. When a newer
stable release (vX.Y.Z) is out, this fetches the two tags (trees only; file contents just for
what the report reads) and opens "Review Signal-Desktop vX.Y.Z" (label: upstream-desktop):

- ported files that changed: Serein's Swift files cite the upstream file they port in their
  header comments, so each changed upstream file is listed with its Swift ports;
- new upstream files (features not ported yet);
- protocol (.proto) changes, new English strings and the release's "What's new" text, and new
  remote-config flags;
- the commits, one line each.

An open review issue for an older release is retitled and rewritten, not duplicated. After the
review, bump Tools/upstream-desktop.txt to the reviewed tag.

    Tools/check-upstream-desktop.py [--dry-run] [--tag vX.Y.Z] [--since vX.Y.Z]

Needs git, and gh authenticated (GH_TOKEN in GitHub Actions) unless --dry-run.
"""
import argparse
import json
import re
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIN = ROOT / "Tools" / "upstream-desktop.txt"
UPSTREAM = "https://github.com/signalapp/Signal-Desktop"
LABEL = "upstream-desktop"
TITLE = "Review Signal-Desktop "
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
ANY = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$")
# An upstream path cited in a Swift file's comments.
CITATION = re.compile(r"\b((?:ts|stylesheets|protos|app)/[A-Za-z0-9_./-]+\.(?:tsx|ts|scss|css|proto))\b")
# Where a new upstream file is likely a feature (tests and stories excluded).
FEATURE_DIRS = ("ts/components/", "ts/state/smart/", "ts/services/", "ts/textsecure/", "ts/util/", "ts/groups/", "ts/jobs/",
                "ts/messages/", "ts/axo/", "ts/calling/")
STRINGS = "_locales/en/messages.json"
REMOTE_CONFIG = "ts/RemoteConfig.dom.ts"
FLAG = re.compile(r"'((?:desktop|global|android|ios)\.[A-Za-z0-9_.-]+)'")
BODY_LIMIT = 65_000   # GitHub's issue body limit is 65,536 characters


def run(*args, cwd=ROOT, check=True):
    return subprocess.run(args, cwd=cwd, check=check, text=True, capture_output=True).stdout


def version(tag):
    """Sort key: a stable release sorts after its betas."""
    m = ANY.match(tag)
    if not m:
        return None
    major, minor, patch, beta = m.groups()
    return (int(major), int(minor), int(patch), int(beta) if beta else 1_000_000)


def stable_tags():
    tags = set()
    for line in run("git", "ls-remote", "--tags", "--refs", f"{UPSTREAM}.git", "v*").splitlines():
        name = line.split("\t")[1].removeprefix("refs/tags/")
        if STABLE.match(name):
            tags.add(name)
    return tags


def citations():
    """Upstream path -> the Swift files citing it (tracked files only)."""
    ports = defaultdict(set)
    for path in run("git", "ls-files", "-z", "*.swift").split("\0"):
        p = ROOT / path
        if not path or not p.is_file():
            continue
        for cited in CITATION.findall(p.read_text(errors="replace")):
            ports[cited].add(path)
    return ports


class Upstream:
    """A blobless, shallow fetch of two tags (and the commits between them)."""

    def __init__(self, directory, old, new):
        self.dir, self.old, self.new = directory, old, new
        self.git("init", "-q")
        self.git("remote", "add", "origin", f"{UPSTREAM}.git")
        self.git("config", "remote.origin.promisor", "true")
        self.git("config", "remote.origin.partialclonefilter", "blob:none")
        refs = [f"refs/tags/{t}:refs/tags/{t}" for t in (old, new)]
        self.git("fetch", "-q", "--depth=1", "--filter=blob:none", "origin", *refs)
        # The commits in `new` that `old` lacks.
        try:
            self.git("fetch", "-q", "--filter=blob:none", f"--shallow-exclude=refs/tags/{old}", "origin", f"refs/tags/{new}:refs/tags/{new}")
        except subprocess.CalledProcessError:
            date = self.git("log", "-1", "--format=%cI", old).strip()
            self.git("fetch", "-q", "--filter=blob:none", f"--shallow-since={date}", "origin", f"refs/tags/{new}:refs/tags/{new}")

    def git(self, *args):
        return run("git", *args, cwd=self.dir)

    def changes(self):
        """(status, path, old path) for every changed file, renames found."""
        out = []
        for line in self.git("diff", "--name-status", "-M", self.old, self.new).splitlines():
            parts = line.split("\t")
            status = parts[0][0]
            if status == "R":
                out.append(("R", parts[2], parts[1]))
            else:
                out.append((status, parts[1], parts[1]))
        return out

    def numstat(self, paths):
        stats = {}
        if not paths:
            return stats
        for line in self.git("diff", "--numstat", "-M", self.old, self.new, "--", *paths).splitlines():
            added, removed, path = line.split("\t", 2)
            path = re.sub(r"\{(.*) => (.*)\}", r"\2", path).split(" => ")[-1]
            stats[path] = (added, removed)
        return stats

    def show(self, tag, path):
        try:
            return self.git("show", f"{tag}:{path}")
        except subprocess.CalledProcessError:
            return ""

    def diff(self, path):
        return self.git("diff", self.old, self.new, "--", path)

    def commits(self):
        return self.git("log", "--no-merges", "--format=%h%x09%s", f"{self.old}..{self.new}").splitlines()


def inert(text):
    """Upstream text made safe for an issue: no @mentions, no #123 links to Serein's issues."""
    return re.sub(r"#(?=\d)", "#\u200b", text.replace("@", "@\u200b"))


def strings(text):
    try:
        return {k: (v.get("messageformat") if isinstance(v, dict) else v) for k, v in json.loads(text or "{}").items()}
    except json.JSONDecodeError:
        return {}


def fit(lines, budget, more):
    """`lines` cut to `budget` characters, ending with how many were left out."""
    out, used = [], 0
    for i, line in enumerate(lines):
        if used + len(line) + 1 > budget:
            out.append(f"- … {len(lines) - i} more {more}")
            break
        out.append(line)
        used += len(line) + 1
    return out


def short(swift):
    """A Swift path without its package boilerplate: SignalUI/Components/…, App/…"""
    return re.sub(r"^(?:Packages/(\w+)/Sources/\1|App/SignalSafe/Sources/SignalSafe)/", lambda m: (m.group(1) or "App") + "/", swift)


def source(path):
    """An upstream source file (not a test, story, screenshot or fixture)."""
    return (path.endswith((".ts", ".tsx", ".scss")) and "__screenshots__" not in path and not re.search(r"/_?test", path)
            and not re.search(r"(_test|\.test|\.stories|\.d)\.(ts|tsx)$", path))


def report(up, old, new):
    changes = up.changes()
    ports = citations()
    changed = {path: (status, before) for status, path, before in changes}
    compare = f"{UPSTREAM}/compare/{old}...{new}"
    sections = []

    # Strings: the release's "What's new" first, the new keys later.
    new_keys, after = [], {}
    if STRINGS in changed:
        before, after = strings(up.show(old, STRINGS)), strings(up.show(new, STRINGS))
        new_keys = sorted(set(after) - set(before))
    whats_new = [k for k in new_keys if k.startswith("icu:WhatsNew__")]
    if whats_new:
        sections.append("\n".join(["### What's new", "", "Upstream's own summary for users:", ""]
                                  + [f"> {inert(str(after[k]))}" for k in whats_new]))

    # Protocol changes.
    protos = sorted(p for p in changed if p.startswith("protos/") and p.endswith(".proto"))
    lines = [f"### Protocol changes ({len(protos)})", ""]
    for p in protos:
        lines += [f"<details><summary><code>{p}</code></summary>", "", "```diff", up.diff(p).strip()[:4000], "```", "</details>", ""]
    sections.append("\n".join(lines)[:12_000])

    # Remote-config flags.
    if REMOTE_CONFIG in changed:
        before_flags = set(FLAG.findall(up.show(old, REMOTE_CONFIG)))
        after_flags = set(FLAG.findall(up.show(new, REMOTE_CONFIG)))
        lines = ["### Remote-config flags", ""]
        lines += [f"- added `{f}`" for f in sorted(after_flags - before_flags)]
        lines += [f"- removed `{f}`" for f in sorted(before_flags - after_flags)]
        sections.append("\n".join(lines))

    # Ported files that changed (by old path: that is the path our comments cite).
    touched = []
    for status, path, before in changes:
        swift = ports.get(before) or ports.get(path)
        if swift:
            touched.append((before, path, status, sorted(swift)))
    stats = up.numstat([p for _, p, s, _ in touched if s != "D"])
    items = []
    for before, path, status, swift in sorted(touched):
        what = {"M": "modified", "D": "**deleted**", "R": f"**moved** to `{path}`"}.get(status, status)
        add, rem = stats.get(path, ("?", "?"))
        delta = f" +{add} −{rem}" if status in "MR" else ""
        link = f"{UPSTREAM}/blob/{new}/{path}" if status != "D" else f"{UPSTREAM}/blob/{old}/{before}"
        items.append(f"- [ ] [`{before}`]({link}) {what}{delta} → {', '.join(f'`{short(s)}`' for s in swift)}")
    sections.append("\n".join([f"### Ported files that changed ({len(touched)})", "",
                               "Each upstream file our Swift ports cite, with its change and the Swift files to update.", ""]
                              + fit(items, 26_000, f"(see {compare})")))

    # New upstream source files where features live.
    added = sorted(p for s, p, _ in changes if s == "A" and p.startswith(FEATURE_DIRS) and source(p))
    items = [f"- [ ] [`{p}`]({UPSTREAM}/blob/{new}/{p})" for p in added]
    sections.append("\n".join([f"### New upstream files ({len(added)})", "", "Possibly new features; decide whether to port.", ""]
                              + fit(items, 10_000, f"(see {compare})")))

    # The other new strings, by prefix.
    groups = defaultdict(list)
    for k in new_keys:
        if k not in whats_new:
            groups[re.split(r"__|--", k.removeprefix("icu:"))[0]].append(k)
    if groups:
        items = [f"- **{prefix}** ({len(keys)}): " + ", ".join(f"`{k.removeprefix('icu:')}`" for k in keys[:12])
                 + (" …" if len(keys) > 12 else "") for prefix, keys in sorted(groups.items())]
        sections.append("\n".join([f"### New English strings ({len(new_keys) - len(whats_new)})", ""]
                                  + fit(items, 5_000, "prefixes")))

    head = (f"Serein is reviewed up to Signal-Desktop **{old}** (`Tools/upstream-desktop.txt`); **{new}** is out.\n\n"
            f"- Release: {UPSTREAM}/releases/tag/{new}\n- Changes: {compare}\n\n"
            "- [ ] Port what Serein should have (one issue or commit per feature)\n"
            f"- [ ] Bump `Tools/upstream-desktop.txt` to `{new}`\n")
    tail = "\n\n_Opened by Tools/check-upstream-desktop.py (.github/workflows/upstream-releases.yml)._"
    body = head + "\n" + "\n\n".join(sections)
    commits = up.commits()
    items = []
    for line in commits:
        sha, subject = line.split("\t", 1)
        items.append(f"- [`{sha}`]({UPSTREAM}/commit/{sha}) {inert(subject)}")
    room = BODY_LIMIT - len(body) - len(tail) - 200
    body += "\n\n" + "\n".join([f"### Commits ({len(commits)})", ""] + fit(items, max(0, room), f"(see {compare})"))
    return body + tail


def open_review_issue():
    issues = json.loads(run("gh", "issue", "list", "--label", LABEL, "--state", "open", "--limit", "100", "--json", "number,title"))
    return next((i for i in issues if i["title"].startswith(TITLE)), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="print the issue body; create or edit no issue")
    parser.add_argument("--tag", help="review this release instead of the newest")
    parser.add_argument("--since", help="review from this tag instead of Tools/upstream-desktop.txt")
    args = parser.parse_args()
    pinned = args.since or PIN.read_text().strip()
    latest = args.tag or max(stable_tags(), key=version)
    if version(latest) <= version(pinned):
        print(f"Signal-Desktop: reviewed up to {pinned}; {latest} is the newest release")
        return
    title = TITLE + latest
    print(f"Signal-Desktop: {pinned} -> {latest}")
    with tempfile.TemporaryDirectory() as d:
        body = report(Upstream(d, pinned, latest), pinned, latest)
    if args.dry_run:
        print(body)
        return
    run("gh", "label", "create", LABEL, "--color", "1D76DB", "--description", "A Signal-Desktop release to review for Serein", "--force")
    existing = open_review_issue()
    if existing is None:
        print(run("gh", "issue", "create", "--title", title, "--label", LABEL, "--body", body).strip())
    elif existing["title"] != title:
        number = str(existing["number"])
        run("gh", "issue", "edit", number, "--title", title, "--body", body)
        run("gh", "issue", "comment", number, "--body", f"Superseded: {latest} is now the newest release; the list above covers {pinned}…{latest}.")
        print(f"  updated #{number}")
    else:
        print(f"  already open: #{existing['number']}")


if __name__ == "__main__":
    main()
