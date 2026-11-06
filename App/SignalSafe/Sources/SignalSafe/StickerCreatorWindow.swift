// File → Create/upload sticker pack (upstream: the sticker-creator window): StickerCreator
// over the sandboxed media service (each image becomes a 512 px sticker or is refused) and
// StickerPackUpload (V1 encryption, S3 forms from the chat server, CDN0).

import AppKit
import Foundation
import MediaXPCInterface
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

@MainActor enum StickerCreatorWindow {
    static var window: NSWindow?

    static func show(session: SignalSession, i18n: Localizer) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        guard let upload = session.stickerUpload() else { return }
        let media = session.media
        let model = StickerCreatorModel(process: { data in
            guard let s = try? await media.stickerImage(data) else { return .refused("StickerCreator--Toasts--errorProcessing") }
            if let refusal = s.refusal { return .refused(refusal.rawValue) }
            return .sticker(data: s.data, contentType: s.contentType,
                            preview: RGBAImage(width: s.previewWidth, height: s.previewHeight, pixels: s.previewRGBA, scale: 2))
        }, upload: upload)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = i18n("ArtCreator--title")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: StickerCreator(model: model, onClose: { close() })
            .environment(\.i18n, i18n).axoModalHost().axoViewport())
        w.center()
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        window = w
    }

    static func close() { window?.close() }
}
