#!/usr/bin/env python3
"""Run async regressions, then require each reverted boundary to fail at runtime.

Temporarily changes one source file at a time; always restores its exact original bytes.
Do not run alongside another build or editor changing these sources.
"""
from pathlib import Path
import re
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
''', "", "retained account changed trust"),
    ("resend drops group context", CORE, "CrossSliceSendTests",
     "Messaging/SendLog.swift", "payload.groupId = groupId", "payload.groupId = Data(); _ = groupId",
     "resend lost group membership check"),
    ("resend trusts its earlier lookup", CORE, "CrossSliceSendTests",
     "Messaging/MessageSender.swift", "if let resend { try SendLog.authorize(db, resend, ourAci: account.aci) }", "_ = resend",
     "resend used a revoked log lookup"),
    ("publication ignores changed snapshot", CORE, "AttachmentPublicationTests",
     "Attachments/AttachmentDownloadManager.swift", "a.hasSameDownloadSource(as: job.attachment), a.pending == true", "a.pending == true",
     "stale completion published"),
    ("publication ignores replaced lease", CORE, "AttachmentPublicationTests",
     "Attachments/AttachmentDownloadManager.swift", 'static func replace(_ db: Database, job: AttachmentDownloadJob, _ change: (MessageAttachment) -> MessageAttachment) throws {\n        if let lease = job.leaseId {', 'static func replace(_ db: Database, job: AttachmentDownloadJob, _ change: (MessageAttachment) -> MessageAttachment) throws {\n        if let lease = Optional<String>.none {',
     "stale completion published"),
    ("old completion replaces the new lease", CORE, "AttachmentPublicationTests",
     "Attachments/AttachmentDownloadManager.swift", 'static func finish(_ db: Database, job: AttachmentDownloadJob) throws {\n        if let lease = job.leaseId {', 'static func finish(_ db: Database, job: AttachmentDownloadJob) throws {\n        if let lease = Optional<String>.none {',
     "old completion changed replacement lease"),
    ("resend binds only a reusable row ID", CORE, "BoundaryReviewRegressionTests",
     "Messaging/SendLog.swift", "current == snapshot.payload", "current.id == snapshot.payload.id",
     "reused row ID authorized a different payload"),
    ("download runs share a task handle", CORE, "BoundaryReviewRegressionTests",
     "Attachments/AttachmentDownloadManager.swift", '|\\(job.signature)|\\(UUID().uuidString)"', '|\\(job.signature)"',
     "replacement overwrote a running task handle"),
    ("download overwrites reference metadata", CORE, "BoundaryReviewRegressionTests",
     "Attachments/AttachmentDownloadManager.swift", "a.applyingDownloadResult(change(a))", "change(a)",
     "reference metadata was overwritten"),
    ("remaining source is not requeued", CORE, "BoundaryReviewRegressionTests",
     "Attachments/AttachmentDownloadManager.swift", "$0.1.pending == true", "$0.1.pending == false",
     "remaining source lost its job"),
    ("video resumes cancelled rewind", UI, "PlaybackCancellationTests",
     "Video/VideoPlaybackEngine.swift", "guard gen == generation, intent == playbackEpoch, isLoaded else { return }", "_ = gen; _ = intent",
     "cancelled playback restarted"),
    ("audio pause ignores pending load", UI, "PlaybackCancellationTests",
     "Audio/AudioPlaybackEngine.swift", "if isPlaying { pausedAt = currentFrame }", "guard isPlaying else { return }; pausedAt = currentFrame",
     "cancelled load installed a late source"),
]


EXPECTED_TESTS = {
    "old completion replaces the new lease": "staleCompletionCannotPublishOrDeleteAReplacement",
    "ciphertext identity not rechecked": "revocationAfterEncryptionStopsTheActualSend",
    "retained account trusted after replacement": "retainedMessengerCannotApproveAfterAccountReplacement",
    "resend drops group context": "groupResendRetainsMembershipAndBlockBoundary",
    "resend trusts its earlier lookup": "resendLookupIsRepeatedAfterEncryption",
    "publication ignores changed snapshot": "staleCompletionCannotPublishOrDeleteAReplacement",
    "publication ignores replaced lease": "staleCompletionCannotPublishOrDeleteAReplacement",
    "resend binds only a reusable row ID": "reusedLogIdCannotAuthorizeARevokedStorySnapshot",
    "download runs share a task handle": "everyOverlappingRunIsDrained",
    "download overwrites reference metadata": "duplicatePointersPreserveMetadataAndFinishEverySource",
    "remaining source is not requeued": "duplicatePointersPreserveMetadataAndFinishEverySource",
    "video resumes cancelled rewind": "cancelledRewindCannotRestartPlayback",
    "audio pause ignores pending load": "cancelledAudioLoadCannotInstallItsSource",
}


def expected_failure(log, test, assertion):
    """Require the assertion inside a recorded issue belonging to this exact test.

    SwiftPM's xunit output does not include Swift Testing tests on this toolchain. Parse
    issue records conservatively: every subsequent test/suite event ends the record.
    Never use a test-start, test-pass, or suite-wide failure as evidence of a killed mutant.
    """
    log = re.sub(r"\x1b\[[0-9;]*m", "", log)
    header = re.compile(r"^[✘×] Test (\w+)\([^\n]*?\) recorded an issue\b(.*)$")
    event = re.compile(r"^[◇✔✘×] (?:Test|Suite)\b")
    owner, body = None, []
    for line in [*log.splitlines(), "◇ Test end-of-stream"]:
        match = header.match(line)
        if match or event.match(line):
            if owner == test and assertion in "\n".join(body):
                return True
            owner, body = (match.group(1), [match.group(2)]) if match else (None, [])
        elif owner is not None and (line.startswith("↳") or line[:1].isspace()):
            body.append(line)
    return False


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
                result = run(package, f"{tests}[./]{EXPECTED_TESTS[label]}")
                log = result.stdout + result.stderr
                (Path(tmp) / f"{index}.log").write_text(log)
                if result.returncode == 0:
                    raise RuntimeError(f"mutant survived: {label}")
                if not expected_failure(log, EXPECTED_TESTS[label], expected):
                    raise RuntimeError(f"{label} failed without the expected test assertion\n{log}")
                print(f"killed: {label}", flush=True)
            finally:
                source.write_bytes(original)
    print(f"{len(CASES)} async boundary mutants killed")


if __name__ == "__main__":
    main()
