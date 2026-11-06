// Port of sticker-creator/ (the Electron app's separate "Sticker Pack Creator" window): add up
// to 200 images (each converted to a 512px sticker by the sandboxed media service, or refused
// with a toast), give each an emoji, then a title, author and cover; confirm, upload (the pack
// key and encryption are SignalCore's), and share the signal.art link.
//
// Stages: drop → emoji → meta → upload → share. The window's routes and styles follow
// sticker-creator/src/routes/art/* and elements/*; the sign-in and unsupported-browser pages
// (the web app's) don't apply to a window opened from Signal.

import AppKit
import SignalI18n
import SwiftUI
import UniformTypeIdentifiers

/// What the media service made of a dropped file: the sticker's bytes and its pixels to show
/// (decoded in the service: the UI never decodes a dropped file).
public enum StickerCreatorImageResult: Sendable {
    case sticker(data: Data, contentType: String, preview: RGBAImage)
    /// The `StickerCreator--Toasts--…` key.
    case refused(String)
}

@MainActor @Observable
public final class StickerCreatorModel {
    public enum Stage: Sendable, Hashable { case drop, emoji, meta, upload, share }

    public struct Art: Identifiable, Hashable {
        public var id = UUID()
        public var name: String
        public var data: Data?
        public var contentType: String?
        public var preview: RGBAImage?
        public var emoji: String?
    }

    public var stage: Stage = .drop
    public var arts: [Art] = []
    public var title = ""
    public var author = ""
    public var coverId: UUID?
    public var showGuide = false
    public var toast: String?
    public var uploaded = 0
    public var packURL: URL?
    public var confirmingUpload = false

    let process: @Sendable (Data) async -> StickerCreatorImageResult
    let upload: (_ title: String, _ author: String, _ stickers: [(Data, String?)], _ cover: Data, _ progress: @escaping @MainActor () -> Void)
        async throws -> URL
    var uploadTask: Task<Void, Never>?

    public init(process: @escaping @Sendable (Data) async -> StickerCreatorImageResult,
                upload: @escaping (_ title: String, _ author: String, _ stickers: [(Data, String?)], _ cover: Data,
                                   _ progress: @escaping @MainActor () -> Void) async throws -> URL) {
        self.process = process
        self.upload = upload
    }

    public static let maxStickers = 200

    var ready: [Art] { arts.filter { $0.data != nil } }
    var canGoToEmoji: Bool { !ready.isEmpty && ready.count == arts.count }
    var emojisReady: Bool { ready.allSatisfy { $0.emoji != nil } }
    var metaReady: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !author.trimmingCharacters(in: .whitespaces).isEmpty }
    var cover: Art? { arts.first { $0.id == coverId } ?? ready.first }

    /// `onDrop`: each file converted in turn; refused ones leave with a toast.
    public func add(_ files: [(name: String, data: Data)], i18n: Localizer) {
        let room = max(0, Self.maxStickers - arts.count)
        let accepted = files.prefix(room)
        var added = 0
        for file in accepted {
            let art = Art(name: file.name)
            arts.append(art)
            Task {
                let result = await process(file.data)
                guard let i = arts.firstIndex(where: { $0.id == art.id }) else { return }
                switch result {
                case .sticker(let data, let type, let preview):
                    arts[i].data = data
                    arts[i].contentType = type
                    arts[i].preview = preview
                    added += 1
                    toast = i18n("icu:StickerCreator--Toasts--imagesAdded", ["count": .number(Double(added))])
                case .refused(let key):
                    arts.remove(at: i)
                    toast = i18n(key)
                }
            }
        }
    }

    public func remove(_ id: UUID) { arts.removeAll { $0.id == id } }

    public func setEmoji(_ emoji: String, for id: UUID) {
        if let i = arts.firstIndex(where: { $0.id == id }) { arts[i].emoji = emoji }
    }

    func startUpload(i18n: Localizer) {
        guard let cover = cover?.data else { return }
        stage = .upload
        uploaded = 0
        let stickers = ready.compactMap { a in a.data.map { ($0, a.emoji) } }
        uploadTask = Task {
            do {
                packURL = try await upload(title, author, stickers, cover) { self.uploaded += 1 }
                stage = .share
            } catch is CancellationError {
                stage = .meta
            } catch {
                toast = i18n("StickerCreator--Toasts--errorUploading", ["message": .string(String(describing: error))])
                stage = .meta
            }
        }
    }

    func cancelUpload() {
        uploadTask?.cancel()
        stage = .meta
    }

    /// `reset`: "Create another sticker pack".
    public func reset() {
        arts = []
        title = ""
        author = ""
        coverId = nil
        packURL = nil
        stage = .drop
    }
}

public struct StickerCreator: View {
    @Bindable var model: StickerCreatorModel
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(model: StickerCreatorModel, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.onClose = onClose
    }

    static var primaryText: AxoColor { AxoColor(light: LegacyColor.gray90, dark: LegacyColor.white) }
    static var secondaryText: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) }
    static var h2: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 500), size: 14, lineHeight: 18) }
    static var text: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 18) }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content.padding(.horizontal, 64)
                }
            }
            footer
        }
        .background(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95))
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                StickerCreatorToast(text: toast) { model.toast = nil }.padding(.bottom, 16)
            }
        }
        .overlay {
            if model.confirmingUpload {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: i18n("StickerCreator--MetaStage--ConfirmDialog--title--sticker"),
                                          description: i18n("StickerCreator--MetaStage--ConfirmDialog--text--sticker")) {
                        AxoConfirmDialog.Cancel(i18n("StickerCreator--ConfirmDialog--cancel")) { model.confirmingUpload = false }
                        AxoConfirmDialog.Action(i18n("StickerCreator--MetaStage--ConfirmDialog--confirm"), variant: .strongPrimary) {
                            model.confirmingUpload = false
                            model.startUpload(i18n: i18n)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    /// `PageHeader`: 96px, the logo and title, the guidelines link; a rule below.
    var header: some View {
        HStack(spacing: 0) {
            SignalIcon("v3/signal/signal", size: 32, color: AxoColor(LegacyColor.ultramarine), mask: true).frame(width: 32, height: 32).padding(.trailing, 8)
            CSSText(i18n("StickerCreator--title--sticker"), style: CSSTextStyle(fontName: AxoFonts.interName(weight: 500), size: 16, lineHeight: 20),
                    wrap: .nowrap, color: Self.primaryText)
            Spacer()
            Button {
                if let url = URL(string: "https://support.signal.org/hc/articles/360031836512") { NSWorkspace.shared.open(url) }
            } label: {
                CSSText(i18n("StickerCreator--guidelines"), style: Self.text, wrap: .nowrap, color: AxoColor(LegacyColor.ultramarine))
                    .padding(.vertical, 12).padding(.horizontal, 16)
            }
            .buttonStyle(UndimmedButtonStyle())
        }
        .padding(.horizontal, 64)
        .frame(height: 96)
        .overlay(alignment: .bottom) { Rectangle().fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray75)).frame(height: 1) }
        .padding(.bottom, 30)
    }

    @ViewBuilder var content: some View {
        switch model.stage {
        case .drop:
            stageTitle(i18n("icu:StickerCreator--DropStage--title--sticker"), help: i18n("StickerCreator--DropStage--help--sticker"))
            ArtGrid(model: model, mode: .add).padding(.top, 16)
        case .emoji:
            stageTitle(i18n("StickerCreator--EmojiStage--title--sticker"), help: i18n("StickerCreator--EmojiStage--help--sticker"))
            ArtGrid(model: model, mode: .pickEmoji).padding(.top, 16)
        case .meta: meta
        case .upload:
            VStack(spacing: 16) {
                CSSText(i18n("StickerCreator--UploadStage--title--sticker"), style: Self.h2, color: Self.primaryText)
                CSSText(i18n("StickerCreator--UploadStage-uploaded", ["count": .string(String(model.uploaded)), "total": .string(String(model.ready.count + 1))]),
                        style: Self.text, color: Self.secondaryText)
                ProgressBar(fractionComplete: Double(model.uploaded) / Double(max(1, model.ready.count)), isRTL: false).frame(width: 300)
                LegacyButton(i18n("cancel"), variant: .secondary) { model.cancelUpload() }.fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        case .share: share
        }
    }

    func stageTitle(_ title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CSSText(title, style: Self.h2, color: Self.primaryText).padding(.bottom, 8)
            CSSBlockText(help, style: Self.text, color: Self.primaryText).frame(maxWidth: 450, alignment: .leading)
        }
    }

    var meta: some View {
        VStack(alignment: .leading, spacing: 24) {
            CSSText(i18n("StickerCreator--MetaStage--title"), style: Self.h2, color: Self.primaryText)
            labeledInput(i18n("StickerCreator--MetaStage--Field--title"), placeholder: i18n("StickerCreator--MetaStage--Field--title-placeholder"),
                         text: $model.title)
            labeledInput(i18n("StickerCreator--MetaStage--Field--author"), placeholder: i18n("StickerCreator--MetaStage--Field--author-placeholder"),
                         text: $model.author)
            VStack(alignment: .leading, spacing: 8) {
                CSSText(i18n("StickerCreator--MetaStage--Field--cover"), style: Self.h2, color: Self.primaryText)
                CSSText(i18n("StickerCreator--MetaStage--Field--cover--help--sticker"), style: Self.text, color: Self.secondaryText)
                HStack(spacing: 8) {
                    ForEach(model.ready) { art in
                        ArtFrame(art: art, selected: art.id == model.cover?.id, size: 96).onTapGesture { model.coverId = art.id }
                    }
                }
            }
        }
    }

    func labeledInput(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CSSText(label, style: Self.h2, color: Self.primaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.custom(AxoFonts.interName(weight: 400), size: 14))
                .frame(maxWidth: 400)
        }
    }

    var share: some View {
        VStack(alignment: .leading, spacing: 24) {
            CSSText(i18n("StickerCreator--ShareStage--title"), style: Self.h2, color: Self.primaryText)
            CSSBlockText(i18n("StickerCreator--ShareStage--help"), style: Self.text, color: Self.primaryText)
            HStack(spacing: 12) {
                if let cover = model.cover { ArtFrame(art: cover, selected: false, size: 96) }
                VStack(alignment: .leading, spacing: 4) {
                    CSSText(model.title, style: Self.h2, color: Self.primaryText)
                    CSSText(model.author, style: Self.text, color: Self.secondaryText)
                }
            }
            if let url = model.packURL {
                VStack(alignment: .leading, spacing: 8) {
                    CSSText(i18n("StickerCreator--ShareStage--copyTitle"), style: Self.h2, color: Self.primaryText)
                    HStack(spacing: 8) {
                        CSSText(url.absoluteString, style: Self.text, wrap: .truncate, color: Self.primaryText)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray60)))
                        LegacyButton(i18n("StickerCreator--CopyText--button"), variant: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            model.toast = i18n("StickerCreator--Toasts--linkedCopied")
                        }
                        .fixedSize()
                    }
                }
                CSSBlockText(i18n("StickerCreator--ShareStage--callToAction", ["hashtag": .string("#makeprivacystick")]), style: Self.text,
                             color: Self.secondaryText)
            }
        }
    }

    /// The footer: "View margins" on the drop stage, then Back / Next.
    var footer: some View {
        HStack(spacing: 12) {
            if model.stage == .drop && !model.arts.isEmpty {
                Toggle(i18n("StickerCreator--DropStage--showMargins"), isOn: $model.showGuide).toggleStyle(.checkbox)
            }
            Spacer()
            switch model.stage {
            case .drop:
                LegacyButton(i18n("StickerCreator--AppStage--next"), variant: .primary, disabled: !model.canGoToEmoji) { model.stage = .emoji }.fixedSize()
            case .emoji:
                LegacyButton(i18n("StickerCreator--AppStage--prev"), variant: .secondary) { model.stage = .drop }.fixedSize()
                LegacyButton(i18n("StickerCreator--AppStage--next"), variant: .primary, disabled: !model.emojisReady) { model.stage = .meta }.fixedSize()
            case .meta:
                LegacyButton(i18n("StickerCreator--AppStage--prev"), variant: .secondary) { model.stage = .emoji }.fixedSize()
                LegacyButton(i18n("StickerCreator--AppStage--next"), variant: .primary, disabled: !model.metaReady) { model.confirmingUpload = true }.fixedSize()
            case .upload:
                EmptyView()
            case .share:
                LegacyButton(i18n("StickerCreator--ShareStage--createAnother"), variant: .secondary) { model.reset() }.fixedSize()
                LegacyButton(i18n("icu:close"), variant: .primary, action: onClose).fixedSize()
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 16)
    }
}

/// `ArtGrid`: 186px frames, 8px apart, ending with the drop zone (add) or an emoji button
/// under each (pick-emoji).
struct ArtGrid: View {
    enum Mode { case add, pickEmoji }
    @Bindable var model: StickerCreatorModel
    let mode: Mode
    @State private var pickerFor: UUID?
    @State private var dropActive = false
    @Environment(\.i18n) var i18n

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 186), spacing: 8, alignment: .topLeading)], alignment: .leading, spacing: 8) {
            ForEach(model.arts) { art in
                VStack(spacing: 10) {
                    ArtFrame(art: art, selected: false, size: 186, showGuide: model.showGuide)
                        .overlay(alignment: .topTrailing) {
                            if mode == .add {
                                Button { model.remove(art.id) } label: {
                                    SignalIcon("v3/x/x", size: 16, color: AxoColor(LegacyColor.white), mask: true).frame(width: 16, height: 16)
                                        .padding(4).background(Circle().fill(Color(rgba: LegacyColor.blackAlpha40)))
                                }
                                .buttonStyle(UndimmedButtonStyle())
                                .accessibilityLabel(i18n("StickerCreator--DropStage--removeSticker"))
                                .padding(6)
                            }
                        }
                    if mode == .pickEmoji {
                        FunEmojiPickerButton(isOpen: Binding(get: { pickerFor == art.id }, set: { pickerFor = $0 ? art.id : nil }),
                                             selectedEmoji: art.emoji,
                                             picker: AnyView(FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: [], onSelectEmoji: { emoji in
                                                 model.setEmoji(emoji, for: art.id)
                                                 pickerFor = nil
                                             }))))
                    }
                }
            }
            if mode == .add && model.arts.count < StickerCreatorModel.maxStickers {
                dropZone
            }
        }
    }

    /// `DropZone`: click to choose files, or drop them.
    var dropZone: some View {
        Button(action: choose) {
            VStack(spacing: 16) {
                SignalIcon("v3/plus/plus", size: 24, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray45), mask: true).frame(width: 24, height: 24)
                CSSBlockText(dropActive ? i18n("StickerCreator--DropZone--activeText") : i18n("StickerCreator--DropStage--dragDrop--sticker"),
                             style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 14, lineHeight: 20), alignment: .center,
                             color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray45))
                    .padding(.horizontal, 12)
            }
            .frame(width: 186, height: 186)
            .background(RoundedRectangle(cornerRadius: 6).fill(AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray80)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropActive ? AxoColor(LegacyColor.ultramarine) : AxoColor(RGBA(0, 0, 0, 0)), lineWidth: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.compactMap { url in (try? Data(contentsOf: url)).map { (name: url.lastPathComponent, data: $0) } }
            model.add(files, i18n: i18n)
            return !files.isEmpty
        } isTargeted: { dropActive = $0 }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .webP, .jpeg, .gif]
        guard panel.runModal() == .OK else { return }
        let files = panel.urls.compactMap { url in (try? Data(contentsOf: url)).map { (name: url.lastPathComponent, data: $0) } }
        model.add(files, i18n: i18n)
    }
}

/// `ArtFrame`: a 186px rounded frame (gray-25 / gray-60 border) with the sticker, a spinner
/// while it converts, and the 6px margin guide when "View margins" is on.
struct ArtFrame: View {
    let art: StickerCreatorModel.Art
    let selected: Bool
    var size: CGFloat
    var showGuide = false

    var body: some View {
        ZStack {
            if let preview = art.preview {
                PixelImage(preview, fit: .contain)
            } else {
                Spinner(svgSize: .normal)
            }
            if showGuide {
                Rectangle().strokeBorder(AxoColor(LegacyColor.ultramarine), style: StrokeStyle(lineWidth: 1, dash: [4])).padding(6)
            }
        }
        .frame(width: size, height: size)
        .background(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray90))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? AxoColor(LegacyColor.ultramarine) : AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray60),
                                                                lineWidth: selected ? 2 : 1))
    }
}

/// `Toast`: a dark pill at the bottom; click to dismiss, gone after a few seconds.
struct StickerCreatorToast: View {
    let text: String
    let onDismiss: () -> Void
    var body: some View {
        CSSText(text, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 18), wrap: .nowrap,
                color: AxoColor(LegacyColor.white))
            .padding(.vertical, 8).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(rgba: LegacyColor.gray80)))
            .onTapGesture(perform: onDismiss)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(4))
                onDismiss()
            }
    }
}
