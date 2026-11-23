import CryptoKit
import Foundation

/// Event numbers and field numbers in RingRTC's call_summary.proto.
package struct CallTimeline: Sendable {
    package enum Event: UInt64, Encodable, Sendable {
        case iceConnected = 1, iceDisconnected, iceFailed, routeChanged
        case groupDisconnected, groupConnecting, groupConnected, groupReconnecting
    }

    package static var now: UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1_000)) }
    package let start: UInt64
    package private(set) var connected: UInt64?
    package var cellular = false
    package var hadParticipants = false
    package var offerSent: UInt64?
    package var answerSent: UInt64?
    package var answerReceived: UInt64?
    private var iceConnected: UInt64?
    private var reconnects = 0
    private var switches = 0
    private var samples: [StreamStatsSet] = []

    package init() { start = Self.now }
    package mutating func didConnect() { if connected == nil { connected = Self.now } }

    package mutating func record(_ event: Event) {
        let time = Self.now
        switch event {
        case .iceConnected: if iceConnected == nil { iceConnected = time }
        case .iceDisconnected: reconnects += 1
        case .routeChanged: switches += 1
        default: break
        }
        if samples.count == 128 { samples.removeFirst() }
        samples.append(StreamStatsSet(timestamp: time, events: [event.rawValue]))
    }

    package static func hash(callID: UInt64) -> Data {
        var bytes = Data("CALL_SUMMARY_CALL_ID".utf8)
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: callID >> shift)) }
        return Data(SHA256.hash(data: bytes))
    }

    private struct Details: Encodable {
        var stream_summaries: StreamSummaries?
        var ice_candidate_switch_count: UInt64?, ice_reconnect_count: UInt64?, relayed: Bool?
        var offer_sent_time: UInt64?, answer_sent_time: UInt64?, answer_received_time: UInt64?, ice_connected_time: UInt64?
        var protobuf: Data {
            var writer = CallingProtoWriter()
            if let stream_summaries { writer.bytes(1,stream_summaries.protobuf) }
            for (field, value) in [(2,ice_candidate_switch_count),(3,ice_reconnect_count),(5,offer_sent_time),
                                   (6,answer_sent_time),(7,answer_received_time),(8,ice_connected_time)] {
                if let value { writer.integer(UInt32(field),value) }
            }
            if let relayed { writer.integer(4,relayed ? 1 : 0) }
            return writer.data
        }
    }

    package func report(group: Bool, end: UInt64, quality: CallMediaMeasurements.Summary? = nil) -> (bytes: Data, text: String?) {
        var headers = CallingProtoWriter()
        headers.integer(1, 1)
        headers.integer(2, start)
        if let connected { headers.integer(3, connected) }
        headers.integer(4, end)
        headers.integer(5, cellular ? 1 : 0)
        var details = Details(stream_summaries: quality?.streams)
        if !group {
            details.ice_candidate_switch_count = UInt64(switches)
            details.ice_reconnect_count = UInt64(reconnects)
            if let duration = quality?.relayMilliseconds {
                let length = end - min(start,end)
                details.relayed = duration > length/8 || (duration > 0 && length <= 30_000)
            }
            details.offer_sent_time = offerSent
            details.answer_sent_time = answerSent
            details.answer_received_time = answerReceived
            details.ice_connected_time = iceConnected
        }
        var content = CallingProtoWriter()
        content.bytes(group ? 6 : 7, details.protobuf)
        // RingRTC retains the latest thirty stats sets and prunes the oldest first
        // when encoding a report over its 64 KiB binary limit.
        let retainedDetails = headers.data.count + content.data.count <= 65_536
        let prefix = headers.data + (retainedDetails ? content.data : Data())
        let sets = (samples + (quality?.sets ?? [])).sorted { $0.timestamp < $1.timestamp }.suffix(30)
        var available = 65_536 - prefix.count
        var chunks = [Data](), retained = [StreamStatsSet]()
        if retainedDetails {
            for set in sets.reversed() {
                var entry = CallingProtoWriter()
                entry.bytes(8,set.protobuf)
                guard entry.data.count <= available else { break }
                chunks.append(entry.data)
                retained.append(set)
                available -= entry.data.count
            }
        }
        let bytes = chunks.reversed().reduce(into: prefix) { $0.append($1) }
        struct Report: Encodable {
            var version = 1
            let start_time: UInt64, connect_time: UInt64?, end_time: UInt64, cellular: Bool
            let direct_call_summary: Details?, group_call_summary: Details?, stats_sets: [StreamStatsSet]
        }
        let report = Report(start_time: start, connect_time: connected, end_time: end, cellular: cellular,
                            direct_call_summary: !group && retainedDetails ? details : nil,
                            group_call_summary: group && retainedDetails ? details : nil, stats_sets: Array(retained.reversed()))
        let text = (try? JSONEncoder().encode(report)).map { String(decoding: $0, as: UTF8.self) }
        return (bytes,text)
    }
}
