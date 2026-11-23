import SignalRingRTC
import SwiftCalling

extension CallTimeline {
    func summary(reason: CallEndReason, callID: UInt64? = nil, quality: CallMediaMeasurements.Summary? = nil) -> JSONValue {
        let end = max(connected ?? start, Self.now)
        let (data, text) = report(group: callID == nil, end: end, quality: quality)
        let name = String(describing: reason)
        let survey = callID == nil ? hadParticipants : (reason != .appDroppedCall && reason != .remoteReCall)
        return .object([
            "callIdHash": .bytes(callID.map { Self.hash(callID: $0) }),
            "startTime": .int(Int64(connected ?? start)), "endTime": .int(Int64(connected == nil ? start : end)),
            "qualityStats": quality.map(Self.qualityJSON) ?? .null, "rawStats": .bytes(data), "rawStatsText": text.map(JSONValue.string) ?? .null,
            "callEndReasonText": .string(name.prefix(1).uppercased() + name.dropFirst()),
            "isSurveyCandidate": .bool(connected != nil && survey)
        ])
    }

    private static func qualityJSON(_ quality: CallMediaMeasurements.Summary) -> JSONValue {
        func stats(_ media: CallMediaMeasurements.MediaSummary) -> JSONValue {
            .object(["rttMedianMillis": media.rtt.map(JSONValue.double) ?? .null,
                     "jitterMedianSendMillis": media.jitterSend.map(JSONValue.double) ?? .null,
                     "jitterMedianRecvMillis": media.jitterReceive.map(JSONValue.double) ?? .null,
                     "packetLossFractionSend": media.lossSend.map(JSONValue.double) ?? .null,
                     "packetLossFractionRecv": media.lossReceive.map(JSONValue.double) ?? .null])
        }
        return .object(["rttMedianConnectionMillis": quality.connectionRTT.map(JSONValue.double) ?? .null,
                        "audioStats": stats(quality.audio), "videoStats": stats(quality.video)])
    }
}
