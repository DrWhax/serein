// What the app does with a link preview the fetcher service returned
// (SignalLinkPreviewFetcher.xpc fetches the page and image and has the page parsed by
// SignalLinkPreviewParser.xpc; the app never fetches or parses web content itself): the
// image goes to the sandboxed media decoder (`processImageResponse`'s decoding half).

import Foundation
import MediaXPCInterface

public struct LinkPreviewImage: Sendable, Equatable {
    public var data: Data
    public var contentType: String
}

public enum LinkPreviewFetch {
    /// `processImageResponse`: GIFs stay as they are (checked by the decoder), others are
    /// re-encoded by the media service (`scaleImageToLevel`).
    static func processImage(_ fetched: FetchedImage, media: any MediaProcessing) async -> LinkPreviewImage? {
        guard let image = try? fetched.validated() else { return nil }
        if image.contentType == "image/gif" {
            guard (try? await media.imageInfo(image.data).validated()) != nil else { return nil }
            return LinkPreviewImage(data: image.data, contentType: image.contentType)
        }
        guard let scaled = try? await media.scaleForSending(image.data, contentType: image.contentType, level: .one)
            .validated(maxDimension: MediaQualityLevel.one.data.maxDimensions) else { return nil }
        return LinkPreviewImage(data: scaled.data, contentType: scaled.contentType)
    }
}
