import CoreAudio
import Foundation

/// Exercise the production devices under SignalCalling.sb. The optional duplex check
/// keeps microphone samples inside the process and plays them locally with the renderer muted.
@main struct ProbePlayout {
    enum ProbeError: Error { case arguments, noOutput, noDuplex, captureTimeout, deviceStillActive }

    static func main() async {
        do {
            try await run()
        } catch let reason as ProbeEcho.Inconclusive {
            print("Acoustic measurement inconclusive:", reason.rawValue)
            exit(77)
        } catch {
            print("calling device check failed:", error)
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || [["--duplex"], ["--echo"], ["--echo-calibration"], ["--echo-route"]].contains(arguments) else { throw ProbeError.arguments }
        if arguments == ["--echo-calibration"] { try ProbeEcho.calibration(); return }
        ServiceSandbox.requireConfinement("calling speaker", systemFiles: true)
        if arguments == ["--echo-route"] { try ProbeEcho.route(); return }
        if arguments == ["--echo"] { try await ProbeEcho.check(); try await checkStopped(); return }
        let speaker = CallSpeaker(muted: true)
        try await speaker.start()
        do {
            if arguments.isEmpty {
                try await checkOutput(speaker)
            } else {
                try await checkDuplex(speaker)
            }
        } catch {
            await speaker.stop()
            throw error
        }
        await speaker.stop()
        try await checkStopped()
    }

    static func checkStopped() async throws {
        let process = try AudioHardwareSystem.shared.process(for: ProcessInfo.processInfo.processIdentifier)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            if try process?.isRunningOutput != true, try process?.isRunningInput != true { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw ProbeError.deviceStillActive
    }

    static func checkOutput(_ speaker: CallSpeaker) async throws {
        let process = try AudioHardwareSystem.shared.process(for: ProcessInfo.processInfo.processIdentifier)
        let block = [Int16](repeating: 0, count: 960)
        var outputBlocks = 0
        for index in 0..<50 {
            try await speaker.enqueue(block, timestamp: UInt32(index * block.count))
            try await Task.sleep(for: .milliseconds(20))
            if try process?.isRunningOutput == true { outputBlocks += 1 }
        }
        guard outputBlocks >= 5 else { throw ProbeError.noOutput }
        print("calling speaker: Core Audio reported active output for the signed, muted PCM renderer")
    }

    static func checkDuplex(_ speaker: CallSpeaker) async throws {
        let microphone = CallMicrophone()
        let blocks = try await microphone.start()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let process = try AudioHardwareSystem.shared.process(for: ProcessInfo.processInfo.processIdentifier)
                    let hal = AudioHardwareSystem.shared
                    guard let mic = try hal.defaultInputDevice?.uid, let output = try hal.defaultOutputDevice?.uid
                    else { throw ProbeError.noDuplex }
                    var timestamp: UInt32 = 0
                    var simultaneous = 0
                    for await block in blocks {
                        guard block.count == 960 else { throw ProbeError.noDuplex }
                        try await speaker.enqueue(block, timestamp: timestamp)
                        timestamp += UInt32(block.count)
                        if try process?.isRunningInput == true, try process?.isRunningOutput == true {
                            simultaneous += 1
                        }
                        if simultaneous == 5 {
                            try await microphone.select(mic)
                            try await speaker.select(output)
                            simultaneous += 1
                        } else if simultaneous == 12 {
                            try await microphone.select(nil)
                            try await speaker.select(nil)
                            simultaneous += 1
                        }
                        if simultaneous >= 20 { return }
                    }
                    throw ProbeError.noDuplex
                }
                group.addTask {
                    // Allow both HAL startup and the bounded alternate input path to settle.
                    try await Task.sleep(for: .seconds(12))
                    throw ProbeError.captureTimeout
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            await microphone.stop()
            throw error
        }
        await microphone.stop()
        print("calling duplex: captured 20 ms PCM during simultaneous input and muted output across hardware selection and return to the default route")
    }
}
