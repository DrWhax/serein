#!/usr/bin/env python3
"""Run async regressions, then require each reverted boundary to fail at runtime.

Temporarily changes one source file at a time; always restores its exact original bytes.
Do not run alongside another build or editor changing these sources.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CORE = "Packages/SignalCore"
UI = "Packages/SignalUI"
CASES = [
    ("ciphertext identity not rechecked", CORE, "CrossSliceSendTests",
     "Messaging/MessageSender.swift", "encryptedIdentity: identity, resend:", "encryptedIdentity: identity.flatMap { _ -> Data? in nil }, resend:",
     "revoked send reached transport: identity"),
    ("retained account trusted after replacement", CORE, "CrossSliceSendTests",
     "Messaging/Messenger+IdentityApproval.swift",
     '''        guard let active = try Account.load(db), active.aci == account.aci,
              SignalCrypto.constantTimeEqual(active.aciIdentity.publicKey.serialize(), account.aciIdentity.publicKey.serialize()) else {
            throw IdentityReviewError.identityChanged
        }
''', "", "retainedMessengerCannotApproveAfterAccountReplacement"),
    ("resend drops group context", CORE, "CrossSliceSendTests",
     "Messaging/SendLog.swift", "payload.groupId = groupId", "payload.groupId = Data(); _ = groupId",
     "groupResendRetainsMembershipAndBlockBoundary"),
    ("resend trusts its earlier lookup", CORE, "CrossSliceSendTests",
     "Messaging/MessageSender.swift", "if let resend { try SendLog.authorize(db, resend, ourAci: account.aci) }", "_ = resend",
     "resend used a revoked log lookup"),
    ("publication ignores changed snapshot", CORE, "AttachmentPublicationTests",
     "Attachments/AttachmentDownloadManager.swift", "a == job.attachment, a.pending == true", "a.pending == true",
     "staleCompletionCannotPublishOrDeleteAReplacement"),
    ("publication ignores replaced lease", CORE, "AttachmentPublicationTests",
     "Attachments/AttachmentDownloadManager.swift", "if let lease = job.leaseId {", "if let lease = Optional<String>.none {",
     "staleCompletionCannotPublishOrDeleteAReplacement"),
    ("video resumes cancelled rewind", UI, "PlaybackCancellationTests",
     "Video/VideoPlaybackEngine.swift", "guard gen == generation, intent == playbackEpoch, isLoaded else { return }", "_ = gen; _ = intent",
     "cancelled playback restarted"),
    ("audio pause ignores pending load", UI, "PlaybackCancellationTests",
     "Audio/AudioPlaybackEngine.swift", "if isPlaying { pausedAt = currentFrame }", "guard isPlaying else { return }; pausedAt = currentFrame",
     "cancelled load installed a late source"),
]


def run(package, tests):
    return subprocess.run(["swift", "test", "--package-path", str(ROOT / package), "--filter", tests],
                          capture_output=True, text=True, timeout=240)


def main():
    with tempfile.TemporaryDirectory(prefix="async-boundary-mutants-") as tmp:
        for package, tests in dict.fromkeys((x[1], x[2]) for x in CASES):
            result = run(package, tests)
            if result.returncode:
                raise RuntimeError(f"baseline {tests} failed\n{result.stdout}{result.stderr}")
        for index, (label, package, tests, relative, old, new, expected) in enumerate(CASES):
            module = "SignalCore" if package == CORE else "SignalUI"
            source = ROOT / package / "Sources" / module / relative
            original = source.read_bytes()
            text = original.decode()
            if old not in text:
                raise RuntimeError(f"mutant did not apply: {label}")
            try:
                source.write_text(text.replace(old, new, 1))
                result = run(package, tests)
                log = result.stdout + result.stderr
                (Path(tmp) / f"{index}.log").write_text(log)
                if result.returncode == 0:
                    raise RuntimeError(f"mutant survived: {label}")
                if "recorded an issue" not in log or expected not in log:
                    raise RuntimeError(f"{label} failed without the expected test assertion\n{log}")
                print(f"killed: {label}", flush=True)
            finally:
                source.write_bytes(original)
    print(f"{len(CASES)} async boundary mutants killed")


if __name__ == "__main__":
    main()
