import Foundation

struct OpusJitterStatistics {
    var emittedSamples: UInt64 = 0, concealedSamples: UInt64 = 0
    var insertedSamples: UInt64 = 0, removedSamples: UInt64 = 0
    var delayedPackets: UInt64 = 0, latePackets: UInt64 = 0, flushes: UInt64 = 0
    var dredRecoveredSamples: UInt64 = 0
    var fecRecoveredPackets: UInt64 = 0
    var fecReceivedPackets: UInt64 = 0, silentConcealedSamples: UInt64 = 0
    var cumulativeDelaySeconds = 0.0, relativeArrivalDelaySeconds = 0.0
    var cumulativeTargetDelay = 0.0, totalAudioEnergy = 0.0, audioLevel = 0.0
}

/// One receiver per RTP source. Decode on the local 20 ms playout clock so a
/// reordered packet can still arrive before its audio is due. All timestamps,
/// buffering limits and adaptation below use the 48 kHz Opus RTP clock.
struct OpusJitterBuffer {
    private struct Entry {
        let stamp: Int64
        let sequence: UInt16
        let marker: Bool
        let packet: OpusPacket
        let arrival: ContinuousClock.Instant
    }
    struct Block {
        let timestamp: UInt32
        let pcm: [Int16]
    }

    private var pending: [Entry] = []
    private var bytes = 0
    private var pcm: [Int16] = []
    private var provenance: [(count: Int, arrival: ContinuousClock.Instant?)] = []
    private(set) var statistics = OpusJitterStatistics()
    private var repair: CallOpusRecovery.Repair?
    private var repairStamp: Int64?
    private var recovery: CallOpusRecovery?
    private var decoder = OpusSpeechDecoder()

    mutating func setDRED(_ configuration: DREDConfiguration?) {
        repair = nil
        repairStamp = nil
        recovery = configuration.map(CallOpusRecovery.init)
    }

    private var maxGap: Int64 { recovery == nil ? 5760 : 48_000 }
    private var latest: (stamp: Int64, arrival: ContinuousClock.Instant)?
    private var transitOrigin: (stamp: Int64, time: ContinuousClock.Instant)?
    private var transitMinima: [(second: Int, value: Double)] = []
    private var firstArrival: ContinuousClock.Instant?
    private var next: Int64?
    private var lastSequence: UInt16?
    private var concealment = 0
    private var jitter = 0.0
    private var averagePacket = 960.0
    private var occupancy: Double?
    private var correction = 0.0
    private(set) var targetSamples = 1440.0
    private(set) var reorderedPackets = 0
    private(set) var latePackets = 0
    private(set) var concealedSamples = 0
    private(set) var stretchedSamples = 0
    var pendingPackets: Int { pending.count }
    var active: Bool { next != nil || !pending.isEmpty }

    mutating func insert(_ packet: OpusPacket, timestamp: UInt32, sequence: UInt16, marker: Bool,
                         now: ContinuousClock.Instant = .now) {
        // Redundancy for an erased packet arrives in a later packet. Allow an
        // observed two-packet burst plus one 10 ms scheduling margin within the
        // configured protection window and the 160 ms interactive latency cap.
        let baseDelay = recovery.map {
            Double(min(7680, max(1440, 480 + min(2 * packet.sampleCount, $0.configuration.duration * 480))))
        } ?? 1440
        var stamp = Int64(timestamp)
        if let latest {
            let delta = Int64(Int32(bitPattern: timestamp &- UInt32(truncatingIfNeeded: latest.stamp)))
            stamp = latest.stamp + delta
            let elapsed = latest.arrival.duration(to: now) / .seconds(1)
            if elapsed > 2 || (delta > 96_000 && marker) {
                clearPlayout()
                self.latest = nil
            } else if delta > 0 {
                if !marker && delta <= 17_280 {
                    let difference = min(9600, abs(elapsed * 48_000 - Double(delta)))
                    jitter += (difference - jitter) / 16
                    let target = min(7680, baseDelay + 4 * jitter)
                    targetSamples += (target > targetSamples ? 0.5 : 0.025) * (target - targetSamples)
                }
            } else if let next, stamp < next {
                latePackets += 1
                statistics.latePackets += 1
                return
            } else if delta < 0 {
                reorderedPackets += 1
                statistics.delayedPackets += 1
            }
        }
        if latest.map({ stamp > $0.stamp }) ?? true {
            latest = (stamp, now)
            averagePacket += 0.1 * (Double(packet.sampleCount) - averagePacket)
        }
        if let next, stamp < next { return }
        if firstArrival == nil {
            firstArrival = now
            targetSamples = min(7680, baseDelay + 4 * jitter)
        }
        let position = pending.firstIndex { $0.stamp >= stamp } ?? pending.endIndex
        if position < pending.count, pending[position].stamp == stamp { return }
        if packet.containsLBRR { statistics.fecReceivedPackets += 1 }
        recordTransit(stamp: stamp, at: now)
        pending.insert(Entry(stamp: stamp, sequence: sequence, marker: marker, packet: packet, arrival: now), at: position)
        bytes += packet.byteCount
        // Bound both wall-clock span and compressed storage (including Opus padding).
        while let first = pending.first, let last = pending.last,
              pending.count > 128 || bytes > 131_072 || last.stamp - first.stamp > 17_280 {
            discardFirst()
        }
    }

    mutating func render(now: ContinuousClock.Instant = .now) -> Block? {
        if next == nil {
            guard let first = pending.first, let firstArrival,
                  firstArrival.duration(to: now) >= .seconds(targetSamples / 48_000) else { return nil }
            next = first.stamp
        }
        guard var decodeStamp = next else { return nil }
        // A resumed talkspurt (DTX) or a suspended renderer can leave an unbounded
        // timestamp jump. Start fresh at its first audible packet; never synthesize the gap.
        if let first = pending.first, pcm.isEmpty, first.stamp - decodeStamp > maxGap {
            decoder = OpusSpeechDecoder()
            setDRED(recovery?.configuration)
            decodeStamp = first.stamp
            next = decodeStamp
            lastSequence = nil
            concealment = 0
            occupancy = nil
            correction = 0
        }
        let start = decodeStamp - Int64(pcm.count)
        let end = pending.last.map { $0.stamp + Int64($0.packet.sampleCount) } ?? decodeStamp
        let ahead = Double(end - start)
        let desired = targetSamples + averagePacket / 2 + 480
        occupancy = occupancy.map { $0 + 0.04 * (ahead - $0) } ?? desired
        let error = (occupancy ?? desired) - desired
        if abs(error) > 720, !pending.isEmpty || pcm.count >= 960 {
            correction += max(-24, min(24, error / 48))
        } else { correction *= 0.90 }
        let scale = correction >= 120 ? 1 : (correction <= -120 ? -1 : 0)
        // Never decode a future gap to obtain time-scaling lookahead.
        fill(to: scale > 0 && ahead >= 1200 ? 1200 : 960)
        guard pcm.count >= 960 else { return nil }
        var consumed = 960
        var output = Array(pcm.prefix(consumed))
        if scale < 0 || (scale > 0 && pcm.count >= 1200) {
            let scaled = Self.timeScale(pcm, direction: scale)
            consumed += scale * scaled.shift
            correction -= Double(scale * scaled.shift)
            stretchedSamples += consumed - 960
            output = scaled.samples
        }
        let duration = Double(960) / Double(consumed)
        var toConsume = consumed
        while toConsume > 0, let first = provenance.first {
            let count = min(first.count, toConsume)
            if let arrival = first.arrival {
                statistics.cumulativeDelaySeconds += Double(count) * duration * max(0, arrival.duration(to: now) / .seconds(1))
            }
            toConsume -= count
            if count == first.count { provenance.removeFirst() } else { provenance[0].count -= count }
        }
        statistics.cumulativeTargetDelay += Double(output.count) * targetSamples / 48_000
        let energy = output.reduce(0.0) { sum, sample in
            let normalized = Double(sample) / 32768
            return sum + normalized * normalized
        }
        statistics.audioLevel = sqrt(energy / Double(output.count))
        statistics.totalAudioEnergy += energy / 48_000
        statistics.emittedSamples += 960
        statistics.removedSamples += UInt64(max(0, consumed - 960))
        statistics.insertedSamples += UInt64(max(0, 960 - consumed))
        pcm.removeFirst(consumed)
        return Block(timestamp: UInt32(truncatingIfNeeded: start), pcm: output)
    }

    private mutating func fill(to count: Int) {
        while pcm.count < count, let next {
            if let first = pending.first, first.stamp < next { discardFirst(); continue }
            if let first = pending.first, first.stamp == next {
                discardFirst()
                guard let decoded = try? decoder.decode(first.packet) else { continue }
                repair = nil
                repairStamp = nil
                recovery?.observe(decoded)
                pcm += decoded
                provenance.append((decoded.count, first.arrival))
                self.next = next + Int64(decoded.count)
                lastSequence = first.sequence
                concealment = 0
                continue
            }
            if let first = pending.first {
                let distance = first.stamp - next
                guard distance <= maxGap, distance.isMultiple(of: 120) else {
                    // Short tail of an interrupted frame follows the prior talkspurt.
                    if !pcm.isEmpty {
                        let padding = count - pcm.count
                        pcm += repeatElement(0, count: padding)
                        provenance.append((padding, nil))
                        self.next = next + Int64(padding)
                    } else { self.next = first.stamp }
                    return
                }
                let gap = Int(distance)
                if first.marker || lastSequence.map({ $0 &+ 1 == first.sequence }) == true {
                    pcm += repeatElement(0, count: gap)
                } else {
                    if repairStamp != first.stamp {
                        repairStamp = first.stamp
                        repair = recovery?.prepare(first.packet, distance: gap)
                    }
                    if var plan = repair {
                        let block = min(gap, 960)
                        if let result = recovery?.recover(&plan, distance: gap, samples: block) {
                            repair = plan
                            advanceDecoder(samples: block)
                            pcm += result.pcm
                            statistics.dredRecoveredSamples += UInt64(result.recovered)
                            statistics.silentConcealedSamples += result.silent
                            statistics.concealedSamples += UInt64(block - result.recovered)
                            concealedSamples += block - result.recovered
                            provenance.append((block, first.arrival))
                            self.next = next + Int64(block)
                            continue
                        }
                    }
                    let prefix = max(0, gap - 5760)
                    advanceDecoder(samples: prefix)
                    let tail = gap - prefix
                    let recovered = (try? decoder.recover(before: first.packet, samples: tail)) ?? decoder.conceal(samples: tail)
                    // A 40/60 ms SILK frame can protect any subset of its 20 ms
                    // blocks. Fill only the unprotected spans and advance the neural
                    // history on each genuine recovered block in time order.
                    let primary = [Int16](repeating: 0, count: prefix) + recovered
                    let intervals = decoder.recoveredIntervals.map { ($0.lowerBound+prefix)..<($0.upperBound+prefix) }
                    if !intervals.isEmpty { statistics.fecRecoveredPackets += 1 }
                    var cursor = 0
                    for interval in intervals + [gap..<gap] {
                        let missing = interval.lowerBound - cursor
                        if missing > 0 {
                            let samples = recovery?.conceal(samples: missing) ?? Array(primary[cursor..<interval.lowerBound])
                            pcm += samples
                            statistics.silentConcealedSamples += Self.silence(samples)
                            statistics.concealedSamples += UInt64(missing)
                            concealedSamples += missing
                        }
                        if !interval.isEmpty {
                            let repaired = Array(primary[interval])
                            recovery?.observe(repaired)
                            pcm += repaired
                        }
                        cursor = interval.upperBound
                    }
                }
                provenance.append((gap, first.arrival))
                self.next = first.stamp
                continue
            }
            // Extend the last speech for at most 60 ms without another packet; a
            // muted peer must not keep producing audio or a fictitious AV sync clock.
            guard concealment < 2880 else {
                if pcm.isEmpty { clearPlayout() }
                else {
                    let padding = count - pcm.count
                    pcm += repeatElement(0, count: padding)
                    provenance.append((padding, nil))
                    self.next = next + Int64(padding)
                }
                return
            }
            let gap = min(2880 - concealment, ((count - pcm.count + 119) / 120) * 120)
            let primary = decoder.conceal(samples: gap)
            let generated = recovery?.conceal(samples: gap) ?? primary
            statistics.silentConcealedSamples += Self.silence(generated)
            pcm += generated
            provenance.append((gap, nil))
            statistics.concealedSamples += UInt64(gap)
            concealment += gap
            concealedSamples += gap
            self.next = next + Int64(gap)
        }
    }

    private mutating func advanceDecoder(samples: Int) {
        var remaining = samples
        while remaining > 0 {
            let part = min(5760, remaining)
            _ = decoder.conceal(samples: part)
            remaining -= part
        }
    }

    /// Excess one-way delay relative to the fastest observed transit in the
    /// preceding two seconds. Sender and receiver clocks may have any offset.
    private mutating func recordTransit(stamp: Int64, at now: ContinuousClock.Instant) {
        if transitOrigin == nil { transitOrigin = (stamp, now) }
        guard let origin = transitOrigin else { return }
        let elapsed = origin.time.duration(to: now) / .seconds(1)
        let transit = elapsed - Double(stamp-origin.stamp)/48_000
        let second = Int(elapsed)
        transitMinima.removeAll { $0.second < second-2 }
        if transitMinima.last?.second == second {
            let last = transitMinima.count-1
            transitMinima[last].value = min(transitMinima[last].value, transit)
        } else { transitMinima.append((second, transit)) }
        let minimum = transitMinima.reduce(transit) { min($0, $1.value) }
        statistics.relativeArrivalDelaySeconds += max(0, transit - minimum)
    }

    static func silence(_ pcm: [Int16]) -> UInt64 {
        var count: UInt64 = 0
        for i in stride(from: 0, to: pcm.count, by: 120) {
            let part = pcm[i..<min(pcm.count, i+120)]
            if part.allSatisfy({ $0 == 0 }) { count += UInt64(part.count) }
        }
        return count
    }

    private mutating func discardFirst() { bytes -= pending.removeFirst().packet.byteCount }

    private mutating func clearPlayout() {
        if !pending.isEmpty || !pcm.isEmpty { statistics.flushes += 1 }
        transitOrigin = nil
        transitMinima.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        provenance.removeAll(keepingCapacity: true)
        bytes = 0
        pcm.removeAll(keepingCapacity: true)
        next = nil
        firstArrival = nil
        lastSequence = nil
        concealment = 0
        occupancy = nil
        correction = 0
        decoder = OpusSpeechDecoder()
        setDRED(recovery?.configuration)
    }

    /// Add or remove a pitch-aligned segment. Cross-correlate across an overlap
    /// near the center, then apply complementary ramps to keep both ends continuous.
    private static func timeScale(_ pcm: [Int16], direction: Int) -> (samples: [Int16], shift: Int) {
        let start = 320, overlap = 240
        var winner = 120, best = -Double.infinity
        for shift in stride(from: 96, through: 240, by: 2) {
            var xy = 0.0, xx = 1.0, yy = 1.0
            for i in stride(from: start, to: start+overlap, by: 4) {
                let a = Double(pcm[i]), b = Double(pcm[i + direction*shift])
                xy += a*b
                xx += a*a
                yy += b*b
            }
            let correlation = xy / sqrt(xx * yy)
            if correlation > best { best = correlation; winner = shift }
        }
        var out = Array(pcm.prefix(960))
        for i in start..<960 {
            let b = pcm[i + direction*winner]
            if i >= start + overlap { out[i] = b }
            else {
                let progress = i - start
                let blend = Int(out[i])*(overlap-progress) + Int(b)*progress
                out[i] = Int16(blend / overlap)
            }
        }
        return (out, winner)
    }
}
