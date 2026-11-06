// Camera capture for calls (GumVideoCapturer, ts/calling/VideoSupport.preload.ts): an
// AVCaptureSession on the chosen camera, the device format closest to the requested size and
// frame rate (960×720@30 for 1:1 calls, 640×480 for group calls), frames delivered as packed
// NV12 (CaptureFrames) for ringrtc and the local preview.

import AVFoundation
import CoreMedia
import Foundation

/// `REQUESTED_VIDEO_*` / `REQUESTED_GROUP_VIDEO_*` / `REQUESTED_SCREEN_SHARE_*` (ts/calling/constants).
public enum CallVideoConstants {
    public static let direct = (width: 960, height: 720, framerate: 30)
    public static let group = (width: 640, height: 480, framerate: 30)
    public static let screenShare = (width: 2880, height: 1800, framerate: 5)
    /// `MAX_FRAME_WIDTH` / `MAX_FRAME_HEIGHT`: remote frames larger than this are dropped.
    public static let maxFrame = (width: 2880, height: 1800)
}

/// Receives frames on the capture queue.
final class CaptureFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    let onFrame: @Sendable (CapturedFrame) -> Void
    init(onFrame: @escaping @Sendable (CapturedFrame) -> Void) { self.onFrame = onFrame }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = CaptureFrames.pack(pixels) else { return }
        onFrame(frame)
    }
}

public enum CameraCaptureError: Error, Equatable {
    case notAuthorized
    case noCamera
    case cannotAddInput
    case cannotAddOutput
}

public actor CameraCapture {
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let delegate: CaptureFrameDelegate
    let queue = DispatchQueue(label: "signalsafe.camera-capture")
    var input: AVCaptureDeviceInput?
    public private(set) var isCapturing = false

    public init(onFrame: @escaping @Sendable (CapturedFrame) -> Void) {
        delegate = CaptureFrameDelegate(onFrame: onFrame)
    }

    nonisolated static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
    }

    /// `enumerateMediaDevices` (cameras).
    public nonisolated static func devices() -> [CameraDevice] {
        discovery().devices.map { CameraDevice(deviceId: $0.uniqueID, label: $0.localizedName) }
    }

    public nonisolated static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// `requestPermissions`: asks once; false when denied or restricted.
    public nonisolated static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// The format to capture in: within `maxWidth`×`maxHeight` (either orientation), the
    /// largest area, then one that reaches `framerate`.
    nonisolated static func bestFormat(_ formats: [(width: Int, height: Int, maxRate: Double)], maxWidth: Int, maxHeight: Int, framerate: Int)
        -> Int?
    {
        let fitting = formats.indices.filter { i in
            let f = formats[i]
            return (f.width <= maxWidth && f.height <= maxHeight) || (f.width <= maxHeight && f.height <= maxWidth)
        }
        let candidates = fitting.isEmpty ? Array(formats.indices) : fitting
        return candidates.max { a, b in
            let fa = formats[a], fb = formats[b]
            let areaA = fitting.isEmpty ? -(fa.width * fa.height) : fa.width * fa.height
            let areaB = fitting.isEmpty ? -(fb.width * fb.height) : fb.width * fb.height
            if areaA != areaB { return areaA < areaB }
            return (fa.maxRate >= Double(framerate) ? 1 : 0, fa.maxRate) < (fb.maxRate >= Double(framerate) ? 1 : 0, fb.maxRate)
        }
    }

    /// The output size: the source scaled down (never up) to fit, even dimensions.
    nonisolated static func outputSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let (mw, mh) = width >= height ? (max(maxWidth, maxHeight), min(maxWidth, maxHeight)) : (min(maxWidth, maxHeight), max(maxWidth, maxHeight))
        let scale = min(1, min(Double(mw) / Double(max(1, width)), Double(mh) / Double(max(1, height))))
        let w = max(2, Int((Double(width) * scale).rounded(.down)) & ~1), h = max(2, Int((Double(height) * scale).rounded(.down)) & ~1)
        return (w, h)
    }

    /// `startCapturing`: (re)configures the session for `deviceId` (nil: the default camera).
    public func start(deviceId: String?, maxWidth: Int = CallVideoConstants.direct.width, maxHeight: Int = CallVideoConstants.direct.height,
                      framerate: Int = CallVideoConstants.direct.framerate) throws {
        guard Self.isAuthorized else { throw CameraCaptureError.notAuthorized }
        let devices = Self.discovery().devices
        guard let device = devices.first(where: { $0.uniqueID == deviceId }) ?? AVCaptureDevice.default(for: .video) ?? devices.first else {
            throw CameraCaptureError.noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input, input.device.uniqueID != device.uniqueID {
            session.removeInput(input)
            self.input = nil
        }
        if input == nil {
            let i = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(i) else { throw CameraCaptureError.cannotAddInput }
            session.addInput(i)
            input = i
        }
        let formats = device.formats.map { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (width: Int(d.width), height: Int(d.height), maxRate: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        var size = (width: maxWidth, height: maxHeight)
        if let best = Self.bestFormat(formats, maxWidth: maxWidth, maxHeight: maxHeight, framerate: framerate) {
            let f = device.formats[best]
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = f
                if let range = f.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= Double(framerate) }) {
                    let duration = CMTime(value: 1, timescale: CMTimeScale(framerate))
                    device.activeVideoMinFrameDuration = max(duration, range.minFrameDuration)
                    device.activeVideoMaxFrameDuration = max(duration, range.minFrameDuration)
                }
                device.unlockForConfiguration()
            }
            size = Self.outputSize(width: formats[best].width, height: formats[best].height, maxWidth: maxWidth, maxHeight: maxHeight)
        }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CameraCaptureError.cannotAddOutput }
            session.addOutput(output)
            output.setSampleBufferDelegate(delegate, queue: queue)
        }
        if !session.isRunning {
            session.commitConfiguration()
            session.startRunning()
            session.beginConfiguration()
        }
        isCapturing = true
    }

    /// `stopCapturing`
    public func stop() {
        if session.isRunning { session.stopRunning() }
        isCapturing = false
    }
}

extension CapturedFrame {
    /// The frame as I420 planes for the local preview (VideoRenderer); limited range.
    public var planes: VideoPlanes {
        let ySize = width * height, cw = width / 2, ch = height / 2
        var u = [UInt8](repeating: 0, count: cw * ch), v = u
        var i = 0
        for k in 0..<(cw * ch) {
            u[k] = nv12[ySize + i]
            v[k] = nv12[ySize + i + 1]
            i += 2
        }
        return VideoPlanes(width: width, height: height, y: Array(nv12[0..<ySize]), u: u, v: v, fullRange: false, matrix: 2, time: 0)
    }
}
