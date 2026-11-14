#!/usr/bin/env python3
"""Require an explicit policy for every unsigned 64-bit field in the received schema.

Timestamp fields must be covered by InboundTimestamps. IDs and monetary quantities retain
full wire range; adding a field requires reviewing this classification before shipping it.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
schema = (ROOT / "Packages/SignalCore/Sources/SignalProtos/SignalService.pb.swift").read_text()
policy = (ROOT / "Packages/SignalCore/Sources/SignalCore/Messaging/InboundTimestamps.swift").read_text()
fields = set()
message = None
for line in schema.splitlines():
    if match := re.match(r"nonisolated extension ([\w.]+): SwiftProtobuf.Message", line):
        message = match[1]
    if match := re.search(r"visitor.visit(?:Singular|Repeated|Packed)(?:UInt64|Fixed64)Field\(value: .*, fieldNumber: (\d+)\)", line):
        assert message is not None
        fields.add((message, int(match[1])))
checked = set()
for message, numbers in re.findall(r"(Signalservice_[\w.]+)\.protoMessageName: \[([\d, ]+)\]", policy):
    checked.update((message, int(n)) for n in numbers.split(","))
unsigned = {
    ("Signalservice_CallMessage." + kind, 1) for kind in ["Offer", "Answer", "IceUpdate", "Busy", "Hangup"]
} | {
    ("Signalservice_DataMessage.Payment.Amount.MobileCoin", 1),
    ("Signalservice_SyncMessage.OutgoingPayment.MobileCoin", 2),
    ("Signalservice_SyncMessage.OutgoingPayment.MobileCoin", 3),
    ("Signalservice_SyncMessage.OutgoingPayment.MobileCoin", 6),
    ("Signalservice_SyncMessage.CallEvent", 2),
    ("Signalservice_SyncMessage.CallLogEvent", 4),
    ("Signalservice_AttachmentPointer", 1),
}
missing = fields - checked - unsigned
stale = (checked | unsigned) - fields
conflicting = checked & unsigned
if not fields or missing or stale or conflicting:
    raise SystemExit(f"parser numeric policy mismatch: missing={sorted(missing)}, stale={sorted(stale)}, conflicting={sorted(conflicting)}")
print(f"parser numeric policy: {len(checked)} timestamp fields bounded, {len(unsigned)} unsigned IDs/quantities preserved")
