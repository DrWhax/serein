// Port of ts/components/conversation/ImageGrid.dom.tsx and AttachmentDetailPill.dom.tsx: one
// visual attachment at its timeline size, or 2–5 tiles (more show "+N" on the fifth) with 1px
// gaps, the bubble's curves on the outer corners, the size pill and the "Download N items" pill.

import SignalI18n
import SwiftUI

/// `getImageDimensionsForTimeline`
func imageDimensionsForTimeline(width: Int?, height: Int?, forcedWidth: CGFloat? = nil) -> CGSize {
    guard let w = width, let h = height, w > 0, h > 0 else { return CGSize(width: 200, height: 50) }
    let aspect = Double(h) / Double(w)
    let target = forcedWidth.map(Double.init) ?? max(min(300, Double(w)), 200)
    let candidate = (target * aspect).rounded()
    return CGSize(width: target, height: max(min(450, candidate), 50))
}

public struct ImageGrid: View {
    let attachments: [MessageAttachment]
    let bottomOverlay: Bool
    let direction: MessageDirection
    let isSticker: Bool
    let stickerSize: CGFloat?
    let shouldCollapseAbove: Bool
    let shouldCollapseBelow: Bool
    let withContentAbove: Bool
    let withContentBelow: Bool
    let blurHashDark: Bool?
    let showVisualAttachment: ((Int) -> Void)?
    let showMediaNoLongerAvailableToast: (() -> Void)?
    let cancelDownload: (() -> Void)?
    let startDownload: (() -> Void)?
    @Environment(\.i18n) var i18n

    public init(attachments: [MessageAttachment], direction: MessageDirection, bottomOverlay: Bool = false, isSticker: Bool = false,
                stickerSize: CGFloat? = nil, shouldCollapseAbove: Bool = false, shouldCollapseBelow: Bool = false,
                withContentAbove: Bool = false, withContentBelow: Bool = false, blurHashDark: Bool? = nil,
                showVisualAttachment: ((Int) -> Void)? = nil, showMediaNoLongerAvailableToast: (() -> Void)? = nil,
                cancelDownload: (() -> Void)? = nil, startDownload: (() -> Void)? = nil) {
        self.attachments = attachments
        self.direction = direction
        self.bottomOverlay = bottomOverlay
        self.isSticker = isSticker
        self.stickerSize = stickerSize
        self.shouldCollapseAbove = shouldCollapseAbove
        self.shouldCollapseBelow = shouldCollapseBelow
        self.withContentAbove = withContentAbove
        self.withContentBelow = withContentBelow
        self.blurHashDark = blurHashDark
        self.showVisualAttachment = showVisualAttachment
        self.showMediaNoLongerAvailableToast = showMediaNoLongerAvailableToast
        self.cancelDownload = cancelDownload
        self.startDownload = startDownload
    }

    /// `getCurves`
    var curves: ConversationImage.Corners {
        var c = ConversationImage.Corners()
        let incoming = direction == .incoming
        if shouldCollapseAbove {
            c.topLeft = incoming ? .tiny : .normal
            c.topRight = incoming ? .normal : .tiny
        } else if !withContentAbove {
            c.topLeft = .normal
            c.topRight = .normal
        }
        if withContentBelow {
        } else if shouldCollapseBelow {
            c.bottomLeft = incoming ? .tiny : .none
            c.bottomRight = incoming ? .none : .tiny
        } else {
            c.bottomLeft = .normal
            c.bottomRight = .normal
        }
        return c
    }

    var withBottomOverlay: Bool { bottomOverlay && !withContentBelow }

    /// `renderDownloadPill`'s condition: nothing downloaded, pending or incremental, and some
    /// attachment downloadable.
    var showsDownloadPill: Bool {
        !attachments.contains { $0.isDownloaded || $0.pending || $0.incremental } && !attachments.allSatisfy(\.isPermanentlyUndownloadable)
    }

    var allVisual: Bool { attachments.allSatisfy { $0.isImage || $0.isVideo } }

    func tile(_ i: Int, _ w: CGFloat, _ h: CGFloat, cropWidth: CGFloat = 0, cropHeight: CGFloat = 0, corners: ConversationImage.Corners,
              thumbnail: Bool = true, bottom: Bool = false, noBorder: Bool = false, overlayText: String? = nil,
              downloads: Bool = true) -> some View {
        let a = attachments[i]
        var o = ConversationImage.Options()
        o.bottomOverlay = bottom && withBottomOverlay
        o.noBorder = noBorder
        o.playIconOverlay = a.isVideo
        o.incremental = a.incremental
        o.caption = a.caption
        o.darkOverlay = overlayText != nil
        o.overlayText = overlayText
        let pill = showsDownloadPill
        let show: (() -> Void)? = a.isPermanentlyUndownloadable ? showMediaNoLongerAvailableToast : showVisualAttachment.map { f in { f(i) } }
        return ConversationImage(attachment: a, url: thumbnail ? a.displayThumbnailUrl : a.displayUrl, blurHash: a.blurHash, width: w, height: h,
                                 cropWidth: cropWidth, cropHeight: cropHeight, corners: corners, options: o, blurHashDark: blurHashDark,
                                 startDownload: downloads ? (pill ? nil : startDownload) : nil, cancelDownload: downloads ? cancelDownload : nil,
                                 showVisualAttachment: show, showMediaNoLongerAvailableToast: showMediaNoLongerAvailableToast)
    }

    public var body: some View {
        if !attachments.isEmpty {
            let c = curves
            ZStack(alignment: .topLeading) {
                grid(c)
                AttachmentDetailPill(attachments: attachments.filter { !$0.isPermanentlyUndownloadable },
                                     startDownload: startDownload, cancelDownload: cancelDownload)
                    .padding([.top, .leading], 6)
                if attachments.count > 1 && allVisual && showsDownloadPill { downloadPill }
            }
            .fixedSize()
        }
    }

    @ViewBuilder func grid(_ c: ConversationImage.Corners) -> some View {
        let n = attachments.count
        if n == 1 || !allVisual {
            let a = attachments[0]
            let size = imageDimensionsForTimeline(width: a.width, height: a.height, forcedWidth: isSticker ? stickerSize : nil)
            ConversationImage(attachment: a, url: a.displayUrl, blurHash: a.blurHash, width: size.width, height: size.height, corners: c,
                              options: singleOptions(a), blurHashDark: blurHashDark, startDownload: startDownload, cancelDownload: cancelDownload,
                              showVisualAttachment: a.isPermanentlyUndownloadable ? showMediaNoLongerAvailableToast : showVisualAttachment.map { f in { f(0) } },
                              showMediaNoLongerAvailableToast: showMediaNoLongerAvailableToast)
                .padding(isSticker ? 8 : 0)
        } else if n == 2 {
            HStack(spacing: 1) {
                tile(0, 150, 150, cropWidth: 1, corners: .init(topLeft: c.topLeft, bottomLeft: c.bottomLeft), bottom: true)
                tile(1, 150, 150, corners: .init(topRight: c.topRight, bottomRight: c.bottomRight), bottom: true)
            }
        } else if n == 3 {
            HStack(spacing: 1) {
                tile(0, 200, 200, cropWidth: 1, corners: .init(topLeft: c.topLeft, bottomLeft: c.bottomLeft), thumbnail: false, bottom: true)
                VStack(spacing: 1) {
                    tile(1, 100, 100, cropHeight: 1, corners: .init(topRight: c.topRight))
                    tile(2, 100, 100, corners: .init(bottomRight: c.bottomRight), bottom: true)
                }
            }
        } else if n == 4 {
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    tile(0, 150, 150, cropWidth: 1, cropHeight: 1, corners: .init(topLeft: c.topLeft))
                    tile(1, 150, 150, cropHeight: 1, corners: .init(topRight: c.topRight))
                }
                HStack(spacing: 1) {
                    tile(2, 150, 150, cropWidth: 1, corners: .init(bottomLeft: c.bottomLeft), bottom: true)
                    tile(3, 150, 150, corners: .init(bottomRight: c.bottomRight), bottom: true)
                }
            }
        } else {
            let more = n > 5 ? "+\(n - 5)" : nil
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    tile(0, 150, 150, cropWidth: 1, corners: .init(topLeft: c.topLeft))
                    tile(1, 150, 150, corners: .init(topRight: c.topRight))
                }
                HStack(spacing: 1) {
                    tile(2, 100, 100, cropWidth: 1, corners: .init(bottomLeft: c.bottomLeft), bottom: true, noBorder: isSticker)
                    tile(3, 100, 100, cropWidth: 1, corners: .init(), bottom: true, noBorder: isSticker)
                    tile(4, 100, 100, corners: .init(bottomRight: c.bottomRight), bottom: true, noBorder: isSticker, overlayText: more,
                         downloads: false)
                }
            }
        }
    }

    func singleOptions(_ a: MessageAttachment) -> ConversationImage.Options {
        var o = ConversationImage.Options()
        o.bottomOverlay = withBottomOverlay
        o.noBorder = isSticker
        o.noBackground = isSticker
        o.playIconOverlay = a.isVideo
        o.incremental = a.incremental
        o.caption = a.caption
        return o
    }

    /// `renderDownloadPill`
    var downloadPill: some View {
        SwiftUI.Button { startDownload?() } label: {
            HStack(spacing: 0) {
                SignalIcon("v3/arrow/arrow-down", size: 24, color: AxoColor(LegacyColor.white)).frame(width: 44, height: 44).padding(.trailing, -6)
                CSSText(i18n("icu:downloadNItems", ["count": .number(Double(attachments.count))]), style: LegacyType.body1(), wrap: .nowrap,
                        color: AxoColor(LegacyColor.white))
                    .padding(.trailing, 14)
            }
            .frame(height: 44)
            .background(LegacyColor.blackAlpha80.color, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i18n("icu:startDownload"))
    }
}

/// `AttachmentDetailPill`: the total size (downloaded / total while pending) at the top left
/// until everything is downloaded; for incremental (streamable) media a download / cancel
/// control.
struct AttachmentDetailPill: View {
    let attachments: [MessageAttachment]
    var isGif = false
    let startDownload: (() -> Void)?
    let cancelDownload: (() -> Void)?
    @Environment(\.i18n) var i18n

    var body: some View {
        let allDownloaded = attachments.allSatisfy(\.isDownloaded)
        let total = attachments.reduce(0) { $0 + $1.size }
        if !allDownloaded && total > 0 {
            let downloaded = attachments.reduce(0) { $0 + ($1.isDownloaded ? $1.size : ($1.totalDownloaded ?? 0)) }
            let anyPending = attachments.contains(where: \.pending)
            let sizes = (downloaded > 0 && anyPending ? "\(formatFileSize(downloaded)) / " : "") + formatFileSize(total)
            let text = { (t: String) in
                CSSText(t, style: LegacyType.caption(), wrap: .nowrap, color: .labelPrimaryOncolor).padding(.horizontal, 10)
            }
            Group {
                if attachments.contains(where: \.incremental) {
                    if !anyPending {
                        SwiftUI.Button { startDownload?() } label: {
                            HStack(spacing: 0) {
                                SignalIcon("v3/arrow/arrow-down", size: 16, color: .labelPrimaryOncolor).frame(width: 24, height: 24)
                                    .padding(.leading, 4).padding(.trailing, -11)
                                text(downloaded > 0 ? i18n("icu:AttachmentDetailPill__retryDownloadShort") : formatFileSize(total))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n(downloaded > 0 ? "icu:AttachmentDetailPill__retryDownload" : "icu:startDownload"))
                    } else {
                        SwiftUI.Button { cancelDownload?() } label: {
                            HStack(spacing: 0) {
                                ZStack {
                                    SpinnerV2(value: downloaded > 0 ? Double(downloaded) : nil, min: 0, max: Double(total), marginRatio: 1, size: 24,
                                              strokeWidth: 2)
                                    SignalIcon("v3/stop/stop-fill", size: 12, color: .labelPrimaryOncolor)
                                }
                                .padding(4).padding(.trailing, -8)
                                text(sizes)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n("icu:cancelDownload"))
                    }
                } else {
                    text(sizes + (isGif ? " · GIF" : ""))
                }
            }
            .frame(height: 32)
            .background(LegacyColor.blackAlpha80.color, in: Capsule())
        }
    }
}
