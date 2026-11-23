#!/usr/bin/env python3
"""Open an issue when an upstream Signal library Serein vendors has a newer release.

For each signalapp submodule in .gitmodules (libsignal, ringrtc) this reads the commit the
repository pins (the gitlink, so no submodule checkout is needed), finds its release tag with
`git ls-remote`, and compares it with the newest release. A newer one gets an issue titled
"Bump <name> to <tag>" (label: upstream-release); an open bump issue for an older tag is
retitled and annotated instead of duplicated.

    Tools/check-upstream-releases.py [--dry-run]

Needs git, and gh authenticated (GH_TOKEN in GitHub Actions) unless --dry-run.
"""
import argparse
import configparser
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LABEL = "upstream-release"
RELEASE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")

# What a bump involves, per library (README, Tools/build-app.sh, QA.md).
STEPS = {
    "libsignal": [
        "`git -C vendor/libsignal fetch --tags && git -C vendor/libsignal checkout {tag}`, then stage the gitlink",
        "`Tools/apply-vendor-patches.sh`: every patch in Tools/vendor-patches still applies",
        "`Tools/build-app.sh` (rebuilds the FFI) and `Tools/check-sandbox-profile.sh`",
        "SignalCore tests, including `UpstreamVectorTests` and `Tools/crypto-vectors/generate.sh`",
        "Read the release notes for protocol, zkgroup or network changes that need app changes",
    ],
    "ringrtc": [
        "Native RingRTC is the interoperability reference only (the app ships the Swift engine)",
        "`git -C vendor/ringrtc fetch --tags && git -C vendor/ringrtc checkout {tag}`, then stage the gitlink",
        "`Tools/build-ringrtc-ffi.sh`, then the SignalRingRTC tests against the new reference",
        "Check the release notes for signaling, SFU or media changes the Swift engine must follow",
    ],
}


def run(*args, check=True):
    return subprocess.run(args, cwd=ROOT, check=check, text=True, capture_output=True).stdout


def signal_submodules():
    config = configparser.ConfigParser()
    config.read(ROOT / ".gitmodules")
    for section in config.sections():
        url = config[section]["url"].removesuffix(".git")
        match = re.match(r"https://github\.com/(signalapp)/([\w.-]+)$", url)
        if match:
            yield config[section]["path"], match.group(1), match.group(2)


def version(tag):
    match = RELEASE.match(tag)
    return tuple(map(int, match.groups())) if match else None


def remote_tags(owner, repo):
    """Release tags and the commit each points at (annotated tags peeled)."""
    tags = {}
    for line in run("git", "ls-remote", "--tags", f"https://github.com/{owner}/{repo}.git").splitlines():
        sha, ref = line.split("\t")
        name = ref.removeprefix("refs/tags/")
        peeled = name.endswith("^{}")
        name = name.removesuffix("^{}")
        if version(name) and (peeled or name not in tags):
            tags[name] = sha
    return tags


def pinned_commit(path):
    # "160000 commit <sha>\t<path>"
    return run("git", "ls-tree", "HEAD", path).split()[2]


def open_bump_issue(repo):
    issues = json.loads(run("gh", "issue", "list", "--label", LABEL, "--state", "open", "--limit", "100",
                            "--json", "number,title"))
    return next((i for i in issues if i["title"].startswith(f"Bump {repo} to ")), None)


def body(path, owner, repo, current, latest):
    steps = "\n".join(f"- [ ] {s.format(tag=latest)}" for s in STEPS.get(repo, [f"Update `{path}` to {latest}"]))
    return (f"`{path}` pins **{current}**; **{latest}** is out.\n\n"
            f"- Release: https://github.com/{owner}/{repo}/releases/tag/{latest}\n"
            f"- Changes: https://github.com/{owner}/{repo}/compare/{current}...{latest}\n\n"
            f"{steps}\n\n_Opened by Tools/check-upstream-releases.py (.github/workflows/upstream-releases.yml)._")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="report only; create or edit no issue")
    args = parser.parse_args()
    if not args.dry_run:
        run("gh", "label", "create", LABEL, "--color", "0E8A16", "--description", "A vendored Signal library has a new release",
            "--force")
    for path, owner, repo in signal_submodules():
        tags = remote_tags(owner, repo)
        pinned = pinned_commit(path)
        current = next((t for t, sha in tags.items() if sha == pinned), None)
        latest = max(tags, key=version)
        if current is None:
            print(f"{repo}: pinned {pinned[:10]} is not a release tag; newest is {latest}")
            current = pinned[:10]
        elif version(latest) <= version(current):
            print(f"{repo}: {current} is the newest release")
            continue
        title = f"Bump {repo} to {latest}"
        print(f"{repo}: {current} -> {latest}")
        if args.dry_run:
            continue
        existing = open_bump_issue(repo)
        if existing is None:
            print(run("gh", "issue", "create", "--title", title, "--label", LABEL, "--body", body(path, owner, repo, current, latest)).strip())
        elif existing["title"] != title:
            number = str(existing["number"])
            run("gh", "issue", "edit", number, "--title", title, "--body", body(path, owner, repo, current, latest))
            run("gh", "issue", "comment", number, "--body", f"Superseded: {latest} is now the newest release.")
            print(f"  updated #{number}")
        else:
            print(f"  already open: #{existing['number']}")


if __name__ == "__main__":
    main()
