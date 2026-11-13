#!/usr/bin/env python3
"""Exercise real verification scripts with an oracle that fails before or after output."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = sorted(p for p in (ROOT / "Tools").glob("verify-*.sh") if "oracle explore" in p.read_text())
AUDIT = "1 definitions\ntest depends on axioms: []\n"


class VerificationRunnerTests(unittest.TestCase):
    def run_script(self, script, failure):
        with tempfile.TemporaryDirectory(prefix="verification-runner-") as tmp:
            root = Path(tmp)
            (root / "Tools").mkdir()
            shutil.copy(script, root / "Tools" / script.name)
            name = re.search(r'dir="\$root/Verification/([^"/]+)"', script.read_text())[1]
            folder = root / "Verification" / name
            (folder / name).mkdir(parents=True)
            for source in ["Main.lean", "Audit.lean", name + ".lean"]:
                (folder / source).touch()
            (folder / "lean-toolchain").write_text("stub\n")
            (folder / "audit-expected.txt").write_text(AUDIT)
            (folder / "traces").mkdir()
            (folder / "traces/regressions.txt").write_text("invalid-event\n")
            if name == "CallCapture":
                expected = "".join(f"{mode} sentinel OK\n" for mode in ["any", "ui", "drained", "drained-fifo"])
            else:
                expected = "sentinel OK\n"
            (folder / "explore-expected.txt").write_text(expected)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            lake = bin_dir / "lake"
            lake.write_text('#!/bin/sh\nif [ "$1" = env ]; then cat audit-expected.txt; fi\n')
            lake.chmod(0o755)
            oracle = folder / ".lake/build/bin/oracle"
            oracle.parent.mkdir(parents=True)
            oracle.write_text('''#!/bin/sh
if [ "$1" = check ]; then
    if [ "$FAILURE" = check ]; then echo 'bad trace' >&2; exit 7; fi
    echo 'fails=[] trace'
    exit 0
fi
if [ "$FAILURE" = before ]; then exit 8; fi
if [ "$SLICE" = CallBoundary ]; then echo 'sentinel OK'; else echo 'OK sentinel'; fi
if [ "$FAILURE" = after ]; then exit 9; fi
exit 0
''')
            oracle.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       SKIP_SWIFT="1", UPDATE_EXPECTED="0", FAILURE=failure, SLICE=name)
            return subprocess.run(["sh", str(root / "Tools" / script.name)], env=env,
                                  capture_output=True, text=True, timeout=10)

    def test_successful_oracles_are_accepted(self):
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                result = self.run_script(script, "none")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_explorer_failure_is_not_hidden_by_filters(self):
        for script in SCRIPTS:
            for failure in ["before", "after"]:
                with self.subTest(script=script.name, failure=failure):
                    result = self.run_script(script, failure)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bad_regression_trace_is_rejected(self):
        result = self.run_script(ROOT / "Tools/verify-send.sh", "check")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("bad trace", result.stderr)


if __name__ == "__main__":
    unittest.main()
