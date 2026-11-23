import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Captures only while the caller is unmuted or explicitly warming the microphone.
actor CallMicrophone {
    enum Failure: Error { case busy, permissionDenied, unavailable, closed }
    private var id: UUID?
    private var engine: EngineMicrophone?
    private var graph: UUID?
    private var selected: SelectedMicrophone?
    private var monitor: Task<Void, Never>?
    private var restartedDefault = false
    private var attemptedCaptureSession = false
    private var packets: AsyncStream<[Int16]>.Continuation?
    private var uid: String?
    private let echo: CallEchoControl?
    private let started: (@Sendable (Bool, String?) -> Void)?

    init(uid: String? = nil, echo: CallEchoControl? = nil, started: (@Sendable (Bool, String?) -> Void)? = nil) {
        self.uid = uid
        self.echo = echo
        self.started = started
    }

    func start() async throws -> AsyncStream<[Int16]> {
        let sink = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(6))
        do {
            try await open(sink.continuation)
            started?(true, uid)
            return sink.stream
        } catch {
            started?(false, uid)
            throw error
        }
    }

    /// Initialize the selected device but discard captures before allocating or copying PCM.
    func warmUp() async throws { try await open(nil) }

    private func open(_ sink: AsyncStream<[Int16]>.Continuation?) async throws {
        guard id == nil else { throw Failure.busy }
        let token = UUID()
        id = token
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw Failure.permissionDenied }
            guard id == token, !Task.isCancelled else { throw Failure.closed }
            restartedDefault = false
            attemptedCaptureSession = false
            packets = sink
            sink?.onTermination = { [weak self] _ in Task { await self?.stop(token) } }
            do { try await capture(token) } catch {
                guard id == token, uid != nil else { throw error }
                releaseCapture()
                uid = nil
                try await capture(token)
            }
        } catch {
            stop(token)
            throw error
        }
    }

    func select(_ newUID: String?) async throws {
        guard uid != newUID else { return }
        let previous = uid
        uid = newUID
        guard let token = id, selected != nil || engine != nil else { return }
        releaseCapture()
        restartedDefault = false
        attemptedCaptureSession = false
        do {
            try await capture(token)
        } catch {
            guard id == token, uid == newUID else { throw Failure.closed }
            uid = previous
            if (try? await capture(token)) == nil { stop(token) }
            throw error
        }
    }

    private func capture(_ token: UUID, useCaptureSession: Bool = false) async throws {
        guard id == token else { throw Failure.closed }
        let defaultUID = try AudioHardwareSystem.shared.defaultInputDevice?.uid
        let route = uid ?? defaultUID
        let generation = UUID()
        graph = generation
        let activity = CaptureActivity()
        if !useCaptureSession, route != nil, route == defaultUID {
            engine = try EngineMicrophone(sink: packets, echo: echo, activity: activity) { [weak self] in
                Task { await self?.engineChanged(generation, token: token) }
            }
        } else {
            guard let route else { throw Failure.unavailable }
            let driver = try SelectedMicrophone(uid: route, sink: packets, echo: echo, activity: activity) { [weak self] in
                Task { await self?.failed(generation, token: token) }
            }
            selected = driver
            do { try await driver.start() } catch {
                driver.close()
                guard id == token else { throw Failure.closed }
                guard graph == generation else { return }
                if selected === driver { selected = nil }
                throw error
            }
            guard id == token else { throw Failure.closed }
            guard graph == generation else { return }
        }
        if packets != nil {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if activity.stalled {
                        await self?.stalled(generation, token: token)
                        return
                    }
                }
            }
        }
    }

    private func engineChanged(_ generation: UUID, token: UUID) async {
        guard token == id, graph == generation else { return }
        releaseCapture()
        if (try? await capture(token)) == nil, graph != nil { stop(token) }
    }

    private func failed(_ generation: UUID, token: UUID) async {
        guard graph == generation, id == token else { return }
        releaseCapture()
        uid = nil
        if (try? await capture(token)) == nil, graph != nil { stop(token) }
    }

    private func stalled(_ generation: UUID, token: UUID) async {
        guard id == token, graph == generation else { return }
        // The current monitor exits after this call. Keep its replacement startup cancellable by mute.
        monitor = nil
        if selected != nil {
            await failed(generation, token: token)
        } else if !restartedDefault {
            // HAL may publish an input before its I/O is usable. Reopen it once.
            restartedDefault = true
            await engineChanged(generation, token: token)
        } else if !attemptedCaptureSession {
            // CoreMediaIO and HAL can recover at different times after a device interruption.
            // Try a bounded capture session once, then leave the default HAL tap ready to resume.
            attemptedCaptureSession = true
            releaseCapture()
            do { try await capture(token, useCaptureSession: true) } catch {
                guard id == token else { return }
                releaseCapture()
                if (try? await capture(token)) == nil { stop(token) }
            }
        }
    }

    func stop() { if let id { stop(id) } }

    private func stop(_ token: UUID) {
        guard token == id else { return }
        id = nil
        releaseCapture()
        packets?.finish()
        packets = nil
    }

    private func releaseCapture() {
        monitor?.cancel()
        monitor = nil
        graph = nil
        engine?.stop()
        engine = nil
        echo?.reset()
        selected?.close()
        selected = nil
    }

    isolated deinit {
        releaseCapture()
        packets?.finish()
    }
}

/// The CoreMediaIO driver can wait for a hardware device in startRunning or stopRunning.
/// Keep both calls on the driver's serial dispatch queue. Cancellation closes its PCM
/// gate immediately, independently of the system's completion or a concurrent route change.
final class SelectedMicrophone: Sendable {
    private static let active = Mutex(0)
    private let queue: DispatchQueue
    private let uid: String
    private let delegate: CapturePCM
    private let failed: @Sendable () -> Void
    private let result = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private struct Driver {
        var session: AVCaptureSession?
        var observer: (any NSObjectProtocol)?
        var released = false
    }
    private let driver = Mutex(Driver())

    init(uid: String, sink: AsyncStream<[Int16]>.Continuation?, echo: CallEchoControl?, activity: CaptureActivity,
         queue: DispatchQueue = DispatchQueue(label: "org.serein.call.selectedMicrophone"),
         failed: @escaping @Sendable () -> Void) throws {
        guard Self.active.withLock({ count in
            guard count < 8 else { return false }
            count += 1
            return true
        }) else { throw CallMicrophone.Failure.busy }
        self.uid = uid
        self.queue = queue
        delegate = CapturePCM(sink: sink, echo: echo, activity: activity)
        self.failed = failed
    }

    func start(deadline: Duration = .seconds(3)) async throws {
        let continuation = result.continuation
        let timeout = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            continuation.finish()
        }
        defer { timeout.cancel() }
        queue.async { self.open() }
        var results = result.stream.makeAsyncIterator()
        guard await results.next() == true else { throw CallMicrophone.Failure.unavailable }
    }

    func close() {
        delegate.disable()
        result.continuation.finish()
        queue.async { self.stop() }
    }

    private func open() {
        defer { result.continuation.finish() }
        driver.withLock { state in
            guard !delegate.closed, let device = AVCaptureDevice(uniqueID: uid),
                  device.hasMediaType(.audio), let input = try? AVCaptureDeviceInput(device: device) else { return }
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                    AVLinearPCMIsNonInterleaved: false]
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "org.serein.call.microphonePCM"))
            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            guard !session.inputs.isEmpty, !session.outputs.isEmpty, !delegate.closed else { return }
            let observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: session, queue: nil) { [failed] _ in failed() }
            session.startRunning()
            if !delegate.closed, session.isRunning { result.continuation.yield(true) }
            state.observer = observer
            state.session = session
        }
    }

    private func stop() {
        driver.withLock { state in
            guard !state.released else { return }
            state.released = true
            if let observer = state.observer { NotificationCenter.default.removeObserver(observer) }
            state.observer = nil
            state.session?.stopRunning()
            state.session = nil
            Self.active.withLock { $0 -= 1 }
        }
    }
}

final class CaptureActivity: Sendable {
    private let last = Mutex(ContinuousClock.now)
    func received() { last.withLock { $0 = .now } }
    var stalled: Bool { last.withLock { $0.duration(to: .now) >= .seconds(2) } }
}

private final class CapturePCM: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    private struct State: Sendable {
        var sink: AsyncStream<[Int16]>.Continuation?
        var pcm = CapturedPCM()
        var closed = false
    }
    private let state: Mutex<State>
    private let echo: CallEchoControl?

    private let activity: CaptureActivity
    init(sink: AsyncStream<[Int16]>.Continuation?, echo: CallEchoControl?, activity: CaptureActivity) {
        self.activity = activity
        state = Mutex(State(sink: sink))
        self.echo = echo
    }

    var closed: Bool { state.withLock { $0.closed } }
    func disable() { state.withLock { $0.closed = true; $0.sink = nil; $0.pcm = CapturedPCM() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard state.withLock({ $0.sink != nil }), let format = buffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 48_000,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16, format.mBytesPerFrame == 2,
              format.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger != 0,
              format.mFormatFlags & (kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsBigEndian) == 0,
              (1...8192).contains(buffer.numSamples), let block = buffer.dataBuffer,
              block.dataLength == buffer.numSamples * 2, let bytes = try? block.dataBytes() else { return }
        state.withLock { s in
            guard let sink = s.sink else { return }
            let timestamp = buffer.presentationTimeStamp.convertScale(48_000, method: .default)
            let first = timestamp.isNumeric ? timestamp.value : CallEchoControl.hostFrame - Int64(buffer.numSamples)
            activity.received()
            for frame in s.pcm.append(bytes: bytes, firstFrame: first) {
                sink.yield(echo?.capture(frame.samples, at: frame.at) ?? frame.samples)
            }
        }
    }
}

/// Assemble the capture hardware's arbitrary callback sizes into timestamped 20 ms Opus frames.
struct CapturedPCM {
    private var partial: [Int16] = []
    private var start: Int64 = 0

    mutating func append(bytes: Data, firstFrame: Int64) -> [(samples: [Int16], at: Int64)] {
        guard bytes.count.isMultiple(of: 2), (2...16_384).contains(bytes.count) else { return [] }
        // A capture discontinuity must not splice old audio into a new frame.
        if abs(Double(firstFrame) - Double(start) - Double(partial.count)) > 48 { partial.removeAll(keepingCapacity: true) }
        if partial.isEmpty { start = firstFrame }
        var result: [(samples: [Int16], at: Int64)] = []
        let samples = [UInt8](bytes)
        for i in stride(from: 0, to: samples.count, by: 2) {
            partial.append(Int16(bitPattern: UInt16(samples[i]) | UInt16(samples[i + 1]) << 8))
            if partial.count == 960 {
                result.append((partial, start))
                partial.removeAll(keepingCapacity: true)
                start += 960
            }
        }
        return result
    }
}
