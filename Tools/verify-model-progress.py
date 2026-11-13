#!/usr/bin/env python3
"""Kill no-op, output-dropping and reject-all transitions using positive Lean assertions.

Runs isolated copies. Nonvacuity imports models, not safety proofs, so a broken preservation
proof cannot masquerade as killing an availability mutant.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MUTANTS = {
    "Media": ("{ step s e with out := s.out }", "{ s with decodes := [], save := none }"),
    "Attachments": ("{ step s e with delivered := s.delivered }", "{ s with atts := s.atts.map (fun a => { a with st := .error, path := none }) }"),
    "Identity": ("{ step s e with jobs := s.jobs, sent := s.sent }", "{ s with last := .stale }"),
    "Send": ("{ step s e with out := s.out }", "{ s with jobs := [], refused := s.refused + 1 }"),
    "Group": ("{ step s e with out := s.out }", "{ s with jobs := [] }"),
    "Queue": ("{ step s e with done := s.done, returned := s.returned }", "{ s with loop := none }"),
    "Resend": ("{ step ⟨[]⟩ s e with out := s.out }", "{ s with rows := [], out := [] }"),
}


def build(folder, name):
    return subprocess.run(["lake", "build", f"{name}.Nonvacuity"], cwd=folder,
                          capture_output=True, text=True, timeout=90)


def main():
    killed = 0
    with tempfile.TemporaryDirectory(prefix="lean-progress-") as temporary:
        for name, (drop, reject) in MUTANTS.items():
            folder = Path(temporary) / name
            shutil.copytree(ROOT / "Verification" / name, folder, ignore=shutil.ignore_patterns(".lake"))
            source = folder / name / "Nonvacuity.lean"
            original = source.read_text()
            line = next(line for line in original.splitlines() if line.startswith("def candidate "))
            baseline = build(folder, name)
            if baseline.returncode:
                raise RuntimeError(f"{name}: baseline failed\n{baseline.stdout}{baseline.stderr}")
            for label, body in [("no-op", "s"), ("drop-output", drop), ("reject-all", reject)]:
                source.write_text(original.replace(line, line.split(":=", 1)[0] + ":= " + body))
                result = build(folder, name)
                log = result.stdout + result.stderr
                if result.returncode == 0:
                    raise RuntimeError(f"{name}: {label} survived")
                if "Tactic `decide`" not in log or "false" not in log or "failed to reduce" in log:
                    raise RuntimeError(f"{name}: {label} failed without a counterexample\n{log}")
                print(f"killed: {name} {label}", flush=True)
                killed += 1
    print(f"{killed} model mutants killed")


if __name__ == "__main__":
    main()
