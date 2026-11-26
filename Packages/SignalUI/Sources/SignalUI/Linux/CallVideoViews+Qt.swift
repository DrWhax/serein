#if os(Linux)
import SwiftUI

public struct RemoteVideoView: View {
    let source: (any CallVideoFrameSource)?
    let fit: VideoRenderer.Fit
    let maxWidth, maxHeight: Int
    let onSize: ((Int, Int) -> Void)?
    @State private var image: RGBAImage?

    public init(source: (any CallVideoFrameSource)?, fit: VideoRenderer.Fit = .cover, maxWidth: Int = CallVideoConstants.maxFrame.width,
                maxHeight: Int = CallVideoConstants.maxFrame.height, onSize: ((Int, Int) -> Void)? = nil) {
        self.source = source
        self.fit = fit
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onSize = onSize
    }

    private struct Feed: Equatable {
        let source: ObjectIdentifier?
        let width, height: Int
    }

    public var body: some View {
        ZStack {
            Color.clear
            if let image { PixelImage(image, fit: fit == .cover ? .cover : .contain) }
        }
        .task(id: Feed(source: source.map(ObjectIdentifier.init), width: maxWidth, height: maxHeight)) {
            image = nil
            guard let source, (1...CallVideoConstants.maxFrame.width).contains(maxWidth),
                  (1...CallVideoConstants.maxFrame.height).contains(maxHeight) else { return }
            var buffer = [UInt8](repeating: 0, count: maxWidth * maxHeight * 4)
            var previous: CGSize?
            while !Task.isCancelled {
                if let size = source.receiveVideoFrame(into: &buffer, maxWidth: maxWidth, maxHeight: maxHeight),
                   (1...maxWidth).contains(size.width), (1...maxHeight).contains(size.height),
                   size.width * size.height * 4 <= buffer.count {
                    image = RGBAImage(width: size.width, height: size.height, pixels: Data(buffer.prefix(size.width * size.height * 4)))
                    let measured = CGSize(width: size.width, height: size.height)
                    if measured != previous {
                        previous = measured
                        onSize?(size.width, size.height)
                    }
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
    }
}

@MainActor @Observable public final class LocalVideoModel {
    public private(set) var current: VideoPlanes?
    public private(set) var image: RGBAImage?
    public init() {}
    public func present(_ frame: CapturedFrame) {
        let planes = frame.planes
        current = planes
        image = VideoRenderer.image(planes, mirrored: true)
    }
    public func clear() {
        current = nil
        image = nil
    }
}

public struct LocalVideoView: View {
    let model: LocalVideoModel
    let fit: VideoRenderer.Fit
    public init(model: LocalVideoModel, fit: VideoRenderer.Fit = .cover) {
        self.model = model
        self.fit = fit
    }
    public var body: some View {
        ZStack {
            Color.clear
            if let image = model.image { PixelImage(image, fit: fit == .cover ? .cover : .contain) }
        }
    }
}
#endif
