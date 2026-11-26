#if os(Linux)
import SwiftUI

extension VideoPlaybackEngine {
    func framesForDisplay() -> AsyncStream<VideoPlanes?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VideoPlanes?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in _ = self?.frameSubscribers.removeValue(forKey: id) }
        }
        frameSubscribers[id] = continuation
        continuation.yield(currentFrame)
        return stream
    }
}

public struct VideoView: View {
    let engine: VideoPlaybackEngine
    let fit: VideoRenderer.Fit
    let background: Color
    @Environment(\.displayScale) var displayScale
    @State private var image: RGBAImage?

    public init(engine: VideoPlaybackEngine, fit: VideoRenderer.Fit = .contain, background: Color = .black) {
        self.engine = engine
        self.fit = fit
        self.background = background
    }

    public var body: some View {
        ZStack {
            background
            if let image { PixelImage(image, fit: fit == .cover ? .cover : .contain) }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            if let wanted = Self.displaySize(CGSize(width: size.width * displayScale, height: size.height * displayScale), cover: fit == .cover) {
                engine.setDisplaySize(wanted)
            }
        }
        .task(id: ObjectIdentifier(engine)) {
            for await frame in engine.framesForDisplay() {
                if Task.isCancelled { break }
                image = frame.flatMap { VideoRenderer.image($0, rotation: engine.rotation) }
            }
        }
    }

    static func displaySize(_ size: CGSize, cover: Bool) -> VideoDisplaySize? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 16, size.height >= 16 else { return nil }
        return VideoDisplaySize(width: Int(min(8192, size.width)), height: Int(min(8192, size.height)), cover: cover)
    }
}
#endif
