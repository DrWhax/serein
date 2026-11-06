// Screen sharing (ts/util/desktopCapturer.preload.ts with @indutny/mac-screen-share): a
// ScreenCaptureKit stream of the chosen display or window at up to 2880×1800@5 fps as NV12,
// the last frame repeated once a second while the content is static (WebRTC's minimum frame
// rate), the shareable sources with thumbnails for CallingSelectPresentingSourcesModal, the
// system content-sharing picker, and the screen-recording permission (CGPreflight/Request
// ScreenCaptureAccess, then System Settings).

import AppKit
import CoreMedia
import ScreenCaptureKit
import Synchronization

/// `PresentableSource` (ts/types/Calling.std.ts).
public struct PresentableSource: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isScreen: Bool
    /// nil when the capture failed (the modal shows the error triangle).
    public var thumbnail: RGBAImage?
    /// The thumbnail's size in points (`PresentableSourceImage` width / height).
    public var thumbnailSize: CGSize
    /// The window's app, for its icon (`appIcon`; drawn by the modal from the installed app).
    public var appBundleId: String?

    public init(id: String, name: String, isScreen: Bool, thumbnail: RGBAImage? = nil, thumbnailSize: CGSize? = nil, appBundleId: String? = nil) {
        self.id = id
        self.name = name
        self.isScreen = isScreen
        self.thumbnail = thumbnail
        self.thumbnailSize = thumbnailSize ?? thumbnail?.size ?? Self.thumbnailSize
        self.appBundleId = appBundleId
    }

    /// `PRESENTABLE_SOURCE_THUMBNAIL_REQUESTED_*`
    public static let thumbnailSize = CGSize(width: 184, height: 102)
}

public enum ScreenRecordingPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// Prompts once (the system adds the app to the list); false until the user allows it.
    @discardableResult public static func request() -> Bool { CGRequestScreenCaptureAccess() }
    /// `openSystemPreferencesAction`: Privacy & Security → Screen & System Audio Recording.
    @MainActor public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

/// The stream's output: frames packed on the sample queue; the newest one kept for repeats.
final class ScreenStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    struct State {
        var last: CapturedFrame?
        var lastAt = ContinuousClock.now
        var running = true
    }
    let onFrame: @Sendable (CapturedFrame) -> Void
    let onStop: @Sendable ((any Error)?) -> Void
    let state = Mutex(State())

    init(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = CaptureFrames.pack(pixels) else { return }
        let running = state.withLock { s in
            s.last = frame
            s.lastAt = .now
            return s.running
        }
        if running { onFrame(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.withLock { $0.running = false }
        onStop(error)
    }

    /// The last frame again if nothing new arrived for a second.
    func repeatIfStale() {
        let frame = state.withLock { s -> CapturedFrame? in
            guard s.running, let last = s.last, ContinuousClock.now - s.lastAt >= .seconds(1) else { return nil }
            s.lastAt = .now
            return last
        }
        if let frame { onFrame(frame) }
    }

    func stop() { state.withLock { $0.running = false } }
}

public enum ScreenShareError: Error, Equatable {
    case notAuthorized
    case sourceGone
}

@MainActor
public final class ScreenShareCapture {
    var stream: SCStream?
    var output: ScreenStreamOutput?
    var repeater: Task<Void, Never>?
    let onFrame: @Sendable (CapturedFrame) -> Void
    let onStop: @Sendable ((any Error)?) -> Void
    let queue = DispatchQueue(label: "signalsafe.screen-share")
    /// The shareable content from the last `sources()`, to resolve a picked id.
    var content: SCShareableContent?

    public init(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// Displays and on-screen windows of other apps, with thumbnails (`getSources`).
    public func sources() async throws -> [PresentableSource] {
        guard ScreenRecordingPermission.isGranted else { throw ScreenShareError.notAuthorized }
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        content = c
        let ourPID = ProcessInfo.processInfo.processIdentifier
        var out: [PresentableSource] = []
        for (i, d) in c.displays.enumerated() {
            let name = c.displays.count == 1 ? "Entire Screen" : "Screen \(i + 1)"
            out.append(PresentableSource(id: "screen:\(d.displayID)", name: name, isScreen: true,
                                         thumbnail: await Self.thumbnail(SCContentFilter(display: d, excludingWindows: []), size: CGSize(width: d.width, height: d.height))))
        }
        for w in c.windows where w.isOnScreen && w.windowLayer == 0 && w.owningApplication?.processID != ourPID && w.frame.width > 40 && w.frame.height > 40 {
            let app = w.owningApplication
            let name = [w.title, app?.applicationName].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            out.append(PresentableSource(id: "window:\(w.windowID)", name: name, isScreen: false,
                                         thumbnail: await Self.thumbnail(SCContentFilter(desktopIndependentWindow: w), size: w.frame.size),
                                         appBundleId: app?.bundleIdentifier))
        }
        return out
    }

    static func thumbnail(_ filter: SCContentFilter, size: CGSize) async -> RGBAImage? {
        let config = SCStreamConfiguration()
        let scale = min(PresentableSource.thumbnailSize.width * 2 / max(1, size.width), PresentableSource.thumbnailSize.height * 2 / max(1, size.height))
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return RGBAImage(cgImage: cg, scale: 2)
    }

    /// The installed app's icon (system-provided, from the app bundle).
    @MainActor public static func icon(bundleId: String?) -> NSImage? {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The filter for a source id from `sources()`.
    public func filter(for id: String) throws -> SCContentFilter {
        guard let content else { throw ScreenShareError.sourceGone }
        if id.hasPrefix("screen:"), let d = content.displays.first(where: { "screen:\($0.displayID)" == id }) {
            return SCContentFilter(display: d, excludingWindows: [])
        }
        if id.hasPrefix("window:"), let w = content.windows.first(where: { "window:\($0.windowID)" == id }) {
            return SCContentFilter(desktopIndependentWindow: w)
        }
        throw ScreenShareError.sourceGone
    }

    /// The stream configuration: the content scaled down to fit 2880×1800 (even), 5 fps, NV12.
    nonisolated static func configuration(contentSize: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let px = CameraCapture.outputSize(width: Int(contentSize.width * scale), height: Int(contentSize.height * scale),
                                          maxWidth: CallVideoConstants.screenShare.width, maxHeight: CallVideoConstants.screenShare.height)
        c.width = px.width
        c.height = px.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(CallVideoConstants.screenShare.framerate))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.queueDepth = 3
        c.showsCursor = true
        c.capturesAudio = false
        return c
    }

    /// Starts sharing `filter` (from `filter(for:)` or the system picker).
    public func start(_ filter: SCContentFilter) async throws {
        await stop()
        let out = ScreenStreamOutput(onFrame: onFrame, onStop: onStop)
        let s = SCStream(filter: filter, configuration: Self.configuration(contentSize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale)),
                         delegate: out)
        try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        output = out
        repeater = Task { [out] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                out.repeatIfStale()
            }
        }
    }

    public func stop() async {
        repeater?.cancel()
        repeater = nil
        output?.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
    }
}

/// What the system picker chose, as ids (SCContentFilter is not Sendable; the filter is
/// rebuilt from fresh shareable content on the main actor).
public enum ScreenShareSelection: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case application(display: CGDirectDisplayID, bundleIds: [String])

    init?(_ f: SCContentFilter) {
        switch f.style {
        case .window:
            guard let w = f.includedWindows.first else { return nil }
            self = .window(w.windowID)
        case .application:
            guard let d = f.includedDisplays.first else { return nil }
            self = .application(display: d.displayID, bundleIds: f.includedApplications.map(\.bundleIdentifier))
        default:
            guard let d = f.includedDisplays.first else { return nil }
            self = .display(d.displayID)
        }
    }
}

extension ScreenShareCapture {
    /// The filter for a picker selection, from the current shareable content.
    public func filter(for selection: ScreenShareSelection) async throws -> SCContentFilter {
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        switch selection {
        case .display(let id):
            guard let d = c.displays.first(where: { $0.displayID == id }) else { throw ScreenShareError.sourceGone }
            return SCContentFilter(display: d, excludingWindows: [])
        case .window(let id):
            guard let w = c.windows.first(where: { $0.windowID == id }) else { throw ScreenShareError.sourceGone }
            return SCContentFilter(desktopIndependentWindow: w)
        case .application(let id, let bundleIds):
            guard let d = c.displays.first(where: { $0.displayID == id }) else { throw ScreenShareError.sourceGone }
            return SCContentFilter(display: d, including: c.applications.filter { bundleIds.contains($0.bundleIdentifier) }, exceptingWindows: [])
        }
    }
}

/// The system content-sharing picker (what mac-screen-share presents on macOS 15+).
@MainActor
public final class SystemScreenPicker: NSObject, SCContentSharingPickerObserver {
    var continuation: CheckedContinuation<ScreenShareSelection?, Never>?

    public override init() { super.init() }

    /// Shows the picker; the chosen content, or nil when cancelled.
    public func pick() async -> ScreenShareSelection? {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        picker.defaultConfiguration = config
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        let result = await withCheckedContinuation { c in
            continuation = c
            picker.present()
        }
        picker.remove(self)
        picker.isActive = false
        return result
    }

    func finish(_ s: ScreenShareSelection?) {
        continuation?.resume(returning: s)
        continuation = nil
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = ScreenShareSelection(filter)
        Task { @MainActor in self.finish(selection) }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.finish(nil) }
    }
}

extension RGBAImage {
    /// The pixels of a 32-bit CGImage (a local screenshot), converted to RGBA through its
    /// data provider's bytes; nil for other layouts.
    public init?(cgImage cg: CGImage, scale: CGFloat = 1) {
        guard cg.bitsPerPixel == 32, cg.bitsPerComponent == 8, let data = cg.dataProvider?.data as Data? else { return nil }
        let w = cg.width, h = cg.height, stride = cg.bytesPerRow
        guard w > 0, h > 0, w <= 16384, h <= 16384, stride >= w * 4, data.count >= stride * (h - 1) + w * 4 else { return nil }
        let little = cg.bitmapInfo.contains(.byteOrder32Little)
        let alpha = cg.alphaInfo
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        // Byte positions of R, G, B, A in each pixel.
        let order: [Int] = switch (little, alphaFirst) {
        case (true, true): [2, 1, 0, 3]      // BGRA in memory
        case (true, false): [3, 2, 1, 0]     // ABGR
        case (false, true): [1, 2, 3, 0]     // ARGB
        case (false, false): [0, 1, 2, 3]    // RGBA
        }
        var out = Data(count: w * h * 4)
        let base = data.startIndex
        for y in 0..<h {
            for x in 0..<w {
                let i = base + y * stride + x * 4, o = (y * w + x) * 4
                out[o] = data[i + order[0]]
                out[o + 1] = data[i + order[1]]
                out[o + 2] = data[i + order[2]]
                out[o + 3] = hasAlpha ? data[i + order[3]] : 255
            }
        }
        self.init(width: w, height: h, pixels: out, scale: scale)
    }
}
