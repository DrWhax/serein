// Port of ts/components/MediaEditor.dom.tsx (+ stylesheets/components/MediaEditor.scss): the
// full-window image editor for attachments and stories. Gray-95, always dark: undo/redo at
// the top left and close at the top right (40px down, 24px in); the image fitted into the
// area 64px in from the top and sides with 12px corners (square while cropping); the tools
// under it (22px padding; a 28px first row 24px above a ≥36px second row):
// - default: draw, text, crop and the sticker picker; the emoji picker, the HD selector
//   (when the caller tracks quality), the 400px caption input, Save;
// - draw / text: the hue slider and the tool menus (pen or highlighter and four widths /
//   regular, highlight or outline) in a gray-90 bar, Done;
// - crop: Freeform / Square / 9:16, then Reset, rotate, flip, aspect lock, Done.
// Shortcuts as upstream: Esc (leave the mode, deselect, close), ⌘D / ⌘T / ⌘C, ⌘Z / ⌘⇧Z,
// Delete / Backspace, arrows (⇧ ×20, ⌥ rotate). Closing with changes asks first.

import SignalI18n
import SwiftUI

public struct MediaEditor: View {
    let isCreatingStory: Bool
    let doneButtonLabel: String?
    let isSending: Bool
    let isHighQuality: Bool?
    let isViewOnce: Bool
    let showViewOnceToggle: Bool
    let stickers: FunPanelStickers?
    let onClose: () -> Void
    let onDone: (MediaEditorResult) -> Void
    @State private var state: MediaEditorState
    @State private var caption: String
    @State private var localViewOnce: Bool
    @State private var localHighQuality: Bool
    @State private var stickerPickerOpen = false
    @State private var emojiPickerOpen = false
    @State private var textMenuOpen = false
    @State private var toolMenuOpen = false
    @State private var widthMenuOpen = false
    @State private var confirmDiscard = false
    @State private var isSaving = false
    @FocusState private var textFocused: Bool
    @Environment(\.i18n) var i18n

    /// `image`: the decoded attachment (from the media service). `stickers`: the sticker panel
    /// (the editor adds the time stickers and takes the selection).
    public init(image: RGBAImage, isCreatingStory: Bool = false, doneButtonLabel: String? = nil, isSending: Bool = false, isHighQuality: Bool? = nil,
                isViewOnce: Bool = false, showViewOnceToggle: Bool = false, draftText: String? = nil, stickers: FunPanelStickers? = nil,
                onClose: @escaping () -> Void = {}, onDone: @escaping (MediaEditorResult) -> Void = { _ in }) {
        self.isCreatingStory = isCreatingStory
        self.doneButtonLabel = doneButtonLabel
        self.isSending = isSending
        self.isHighQuality = isHighQuality
        self.isViewOnce = isViewOnce
        self.showViewOnceToggle = showViewOnceToggle
        self.stickers = stickers
        self.onClose = onClose
        self.onDone = onDone
        _state = State(initialValue: MediaEditorState(image: image))
        _caption = State(initialValue: draftText ?? "")
        _localViewOnce = State(initialValue: isViewOnce)
        _localHighQuality = State(initialValue: isHighQuality ?? false)
    }

    static var gray95: AxoColor { AxoColor(LegacyColor.gray95) }
    static var gray90: AxoColor { AxoColor(LegacyColor.gray90) }
    static var gray80: AxoColor { AxoColor(LegacyColor.gray80) }

    var hasChanges: Bool {
        state.canUndo || isCreatingStory || localViewOnce != isViewOnce || (isHighQuality != nil && localHighQuality != isHighQuality)
    }

    public var body: some View {
        AxoThemeOverride(theme: .forceDark) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    media
                        .padding(.top, 64).padding(.horizontal, 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    tools.padding(22).frame(maxWidth: .infinity)
                }
                historyButtons.padding(.top, 40).padding(.leading, 24)
                closeButton
                    .padding(.top, 40).padding(.trailing, 24)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                shortcuts
                if confirmDiscard {
                    ConfirmDiscardDialog(onClose: { confirmDiscard = false }, onDiscard: { confirmDiscard = false; onClose() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Self.gray95)
            .environment(\.colorScheme, .dark)
        }
    }

    func tryClose() {
        if hasChanges { confirmDiscard = true } else { onClose() }
    }

    // MARK: media

    var media: some View {
        GeometryReader { geo in
            let img = state.doc.image
            let zoom = min(geo.size.width / max(img.width, 1), geo.size.height / max(img.height, 1))
            let w = img.width * zoom, h = img.height * zoom
            ZStack(alignment: .topLeading) {
                canvas(zoom: zoom)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: state.mode == .crop ? 0 : 12))
                    .animation(.easeOut(duration: 0.2), value: state.mode == .crop)
                if let id = state.editing, let o = state.doc.objects.first(where: { $0.id == id }) { textEditor(o, zoom: zoom) }
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .onAppear { state.zoom = zoom }
            .onChange(of: zoom) { _, z in state.zoom = z }
        }
    }

    func canvas(zoom: CGFloat) -> some View {
        let renderer = MediaEditorRenderer(background: state.background, moreStylesLabel: i18n("icu:MediaEditor__clock-more-styles"))
        let doc = state.doc
        let overlay = MediaEditorOverlay(selected: state.mode == .crop ? nil : state.selected, crop: state.mode == .crop ? state.crop : nil, editing: state.editing)
        let drawing = state.drawing, color = state.brushColor, width = state.brushWidth, tool = state.drawTool
        return Canvas { ctx, _ in
            renderer.draw(doc, in: ctx, zoom: zoom, overlay: overlay)
            if !drawing.isEmpty {
                var c = ctx
                c.scaleBy(x: zoom, y: zoom)
                let style = tool == .highlighter ? StrokeStyle(lineWidth: width, lineCap: .square, lineJoin: .miter)
                                                 : StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .bevel)
                c.stroke(Path(MediaEditorPencil.path(drawing, width: width)), with: .color(color.swiftUIColor), style: style)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { e in
                if case .none = state.drag, e.translation == .zero { state.begin(e.startLocation) }
                state.changed(e.location)
            }
            .onEnded { e in
                state.ended(e.location, wasTap: hypot(e.translation.width, e.translation.height) < 3)
            })
        .accessibilityLabel(i18n("icu:MediaEditor__input-placeholder"))
    }

    /// The text being typed: a field over the object, in its font and colours.
    func textEditor(_ o: MediaEditorObject, zoom: CGFloat) -> some View {
        let fontSize: CGFloat
        let colors: (fill: RGBA, stroke: RGBA?, background: RGBA?)
        if case .text(_, let style, let hue, let size) = o.kind {
            fontSize = size
            colors = MediaEditorColor.text(style, hue: hue)
        } else {
            fontSize = 12
            colors = (RGBA(1, 1, 1), nil, nil)
        }
        let size = o.size
        let binding = Binding(get: { state.editingText }, set: { state.setText($0) })
        return TextField("", text: binding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Font(MediaEditorText.font(fontSize * o.scale * zoom)))
            .foregroundStyle(colors.fill.swiftUIColor)
            .multilineTextAlignment(.center)
            .background(colors.background?.swiftUIColor ?? .clear)
            .fixedSize()
            .frame(minWidth: max(size.width * o.scale * zoom, 20))
            .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
            .rotationEffect(.degrees(o.angle))
            .position(x: o.center.x * zoom, y: o.center.y * zoom)
            .focused($textFocused)
            .onAppear { textFocused = true }
    }

    // MARK: chrome

    var historyButtons: some View {
        HStack(spacing: 0) {
            control("v3/undo/undo", label: i18n("icu:MediaEditor__control--undo"), disabled: !state.canUndo) { state.undo() }
            control("v3/redo/redo", label: i18n("icu:MediaEditor__control--redo"), disabled: !state.canRedo) { state.redo() }
        }
    }

    var closeButton: some View {
        SwiftUI.Button(action: tryClose) {
            SignalIcon("v3/x/x", size: 20, color: AxoColor(LegacyColor.gray15), mask: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i18n("icu:close"))
    }

    /// `MediaEditor__control`: 32px, 20px radius, 20px margins; a 20px white icon. Selected:
    /// white with a black icon; hover gray-80; disabled icons gray-45.
    func control(_ icon: String, label: String, selected: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        MediaEditorControl(icon: icon, label: label, selected: selected, disabled: disabled, action: action)
            .padding(.horizontal, 20)
    }

    // MARK: tools

    @ViewBuilder var tools: some View {
        VStack(spacing: 0) {
            switch state.mode {
            case .text, .draw:
                Color.clear.frame(height: 28).padding(.bottom, 24)
                HStack(spacing: 0) {
                    toolbar
                    LegacyButton(i18n("icu:done"), variant: .secondary, action: doneEditing)
                }
                .frame(minHeight: 36)
            case .crop:
                HStack(spacing: 0) {
                    preset(.freeform, i18n("icu:MediaEditor__crop-preset--freeform"))
                    preset(.square, i18n("icu:MediaEditor__crop-preset--square"))
                    preset(.vertical, i18n("icu:MediaEditor__crop-preset--9-16"))
                }
                .frame(height: 28).padding(.bottom, 24)
                HStack(spacing: 0) {
                    LegacyButton(i18n("icu:MediaEditor__crop--reset"), variant: .secondary, disabled: !state.doc.image.canReset, action: { state.reset() })
                    HStack(spacing: 0) {
                        cropButton("v2/rotate-outline-24", i18n("icu:MediaEditor__crop--rotate")) { state.rotate() }
                        cropButton("v2/flip-outline-24", i18n("icu:MediaEditor__crop--flip")) { state.flip() }
                        cropButton(state.cropLocked ? "v3/crop/crop-lock" : "v3/crop/crop-unlock", i18n("icu:MediaEditor__crop--lock")) { state.cropLocked.toggle() }
                    }
                    .frame(height: 36).padding(.horizontal, 12).padding(.horizontal, 16)
                    LegacyButton(i18n("icu:done"), variant: .secondary, action: { state.applyCrop() })
                }
                .frame(minHeight: 36)
            case nil:
                HStack(spacing: 0) {
                    control("v2/draw-24", label: i18n("icu:MediaEditor__control--draw"), selected: false) { state.setMode(.draw) }
                    control("v2/text-24", label: i18n("icu:MediaEditor__control--text"), selected: false) { state.setMode(.text) }
                    control("v3/crop/crop-rotate", label: i18n("icu:MediaEditor__control--crop"), selected: false) { state.setMode(.crop) }
                    stickerButton
                }
                .frame(height: 28).padding(.bottom, 24)
                HStack(spacing: 0) {
                    FunEmojiPickerButton(isOpen: $emojiPickerOpen, picker: AnyView(FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: []) { e in caption += e })))
                        .padding(.horizontal, 4)
                        .opacity(localViewOnce ? 0 : 1)
                    if isHighQuality != nil {
                        MediaQualitySelector(isHighQuality: localHighQuality) { localHighQuality = $0 }.padding(.horizontal, 4)
                    }
                    CompositionInput(text: $caption, placeholder: i18n("icu:MediaEditor__input-placeholder"), showViewOnceButton: showViewOnceToggle,
                                     isViewOnceActive: localViewOnce, onToggleViewOnce: {
                                         localViewOnce.toggle()
                                         if localViewOnce { emojiPickerOpen = false }
                                     }, onSubmit: save)
                        .frame(width: 400)
                        .padding(.horizontal, 8)
                    AxoButton.Root(doneButtonLabel ?? i18n("icu:save"), variant: .strongPrimary, size: .md, pending: isSaving || isSending, action: save)
                }
                .frame(minHeight: 36)
            }
        }
    }

    var stickerButton: some View {
        SwiftUI.Button { stickerPickerOpen.toggle() } label: {
            SignalIcon("v3/sticker/sticker", size: 20, color: .labelPrimary, mask: true)
                .frame(width: 32, height: 32)
                .background(stickerPickerOpen ? AxoColor.fillPrimaryPressed : AxoColor(RGBA(0, 0, 0, 0)), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i18n("icu:FunButton__Label--StickerPicker"))
        .axoPopper(id: "MediaEditor.stickers", isPresented: stickerPickerOpen,
                   placement: AxoPopper.Placement(side: .top, align: .center, sideOffset: 4, collisionPadding: 6), dismiss: { stickerPickerOpen = false }) {
            if let stickers {
                FunStickerPicker(panel: stickers.timeStickers { analog in
                    state.addTimeSticker(analog: analog)
                    stickerPickerOpen = false
                }.onSelect { item in
                    if let img = item.image { state.addSticker(img) }
                    stickerPickerOpen = false
                })
            }
        }
    }

    /// `MediaEditor__toolbar`: gray-90, 10px corners, 36px tall, 12px sides, ≥418 wide, 16px margins.
    var toolbar: some View {
        HStack(spacing: 0) {
            HueSlider(label: i18n("icu:CustomColorEditor__hue"), value: $state.slider)
            if state.mode == .text {
                menu(isOpen: $textMenuOpen, icon: "v3/text/text-\(["regular": "square", "highlight": "square-fill", "outline": "outline"][state.textStyle.rawValue]!)-compact",
                     label: i18n("icu:MediaEditor__text--\(state.textStyle.rawValue)")) {
                    AxoDropdownMenu.RadioGroup(value: Binding(get: { state.textStyle.rawValue }, set: { $0.flatMap(MediaEditorTextStyle.init(rawValue:)).map { state.textStyle = $0 } })) {
                        AxoDropdownMenu.RadioItem(i18n("icu:MediaEditor__text--regular"), value: "regular", symbol: "text-square")
                        AxoDropdownMenu.RadioItem(i18n("icu:MediaEditor__text--highlight"), value: "highlight", symbol: "text-square-fill")
                        AxoDropdownMenu.RadioItem(i18n("icu:MediaEditor__text--outline"), value: "outline", symbol: "text-outline")
                    }
                }
            } else {
                menu(isOpen: $toolMenuOpen, icon: "v3/brush/brush-\(state.drawTool == .pen ? "pen" : "highlighter")-compact",
                     label: i18n("icu:MediaEditor__draw--\(state.drawTool.rawValue)")) {
                    AxoDropdownMenu.RadioGroup(value: Binding(get: { state.drawTool.rawValue }, set: { $0.flatMap(MediaEditorDrawTool.init(rawValue:)).map { state.drawTool = $0 } })) {
                        AxoDropdownMenu.RadioItem(i18n("icu:MediaEditor__draw--pen"), value: "pen")
                        AxoDropdownMenu.RadioItem(i18n("icu:MediaEditor__draw--highlighter"), value: "highlighter")
                    }
                }
                menu(isOpen: $widthMenuOpen, icon: "v3/brush_size/brush_size-\(Self.widthName(state.drawWidth))-compact",
                     label: i18n("icu:MediaEditor__draw--\(Self.widthName(state.drawWidth))")) {
                    AxoDropdownMenu.RadioGroup(value: Binding(get: { Self.widthName(state.drawWidth) },
                                                              set: { v in MediaEditorDrawWidth.allCases.first { Self.widthName($0) == v }.map { state.drawWidth = $0 } })) {
                        ForEach(MediaEditorDrawWidth.allCases, id: \.self) { w in
                            AxoDropdownMenu.RadioItem(i18n("icu:MediaEditor__draw--\(Self.widthName(w))"), value: Self.widthName(w), symbol: "brushsize-\(Self.widthName(w))")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 418, minHeight: 36, maxHeight: 36)
        .background(Self.gray90, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    static func widthName(_ w: MediaEditorDrawWidth) -> String {
        switch w {
        case .thin: "thin"
        case .regular: "regular"
        case .medium: "medium"
        case .heavy: "heavy"
        }
    }

    func menu<Items: View>(isOpen: Binding<Bool>, icon: String, label: String, @ViewBuilder items: () -> Items) -> some View {
        AxoDropdownMenu.Root(isOpen: isOpen) {
            SignalIcon(icon, size: 20, color: AxoColor(RGBA(1, 1, 1)), mask: true)
                .contentShape(Rectangle())
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
        } items: { items() }
        .padding(.leading, 14)
    }

    func preset(_ p: MediaEditorCropPreset, _ label: String) -> some View {
        SwiftUI.Button { state.setPreset(p) } label: {
            CSSText(label, style: LegacyType.body1(), wrap: .nowrap, color: AxoColor(RGBA(1, 1, 1)))
                .padding(.vertical, 5).padding(.horizontal, 12)
                .frame(height: 28)
                .background(state.cropPreset == p ? Self.gray80 : AxoColor(RGBA(0, 0, 0, 0)), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    func cropButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) { SignalIcon(icon, size: 20, color: AxoColor(RGBA(1, 1, 1)), mask: true) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .padding(.horizontal, 20)
    }

    // MARK: keyboard

    var shortcuts: some View {
        Group {
            SwiftUI.Button("") { escape() }.keyboardShortcut(.escape, modifiers: [])
            SwiftUI.Button("") { state.setMode(.draw) }.keyboardShortcut("d", modifiers: .command)
            SwiftUI.Button("") { state.setMode(.text) }.keyboardShortcut("t", modifiers: .command)
            if state.editing == nil {
                SwiftUI.Button("") { state.setMode(.crop) }.keyboardShortcut("c", modifiers: .command)
                SwiftUI.Button("") { state.undo() }.keyboardShortcut("z", modifiers: .command)
                SwiftUI.Button("") { state.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                SwiftUI.Button("") { state.deleteSelected() }.keyboardShortcut(.delete, modifiers: [])
                SwiftUI.Button("") { state.deleteSelected() }.keyboardShortcut(.deleteForward, modifiers: [])
                ForEach([(KeyEquivalent.upArrow, 0.0, -1.0, -1.0), (.downArrow, 0, 1, 1), (.leftArrow, -1, 0, -1), (.rightArrow, 1, 0, 1)], id: \.0.character) { k in
                    ForEach([EventModifiers(), .shift, .option, [.shift, .option]], id: \.rawValue) { m in
                        SwiftUI.Button("") {
                            state.nudge(dx: k.1, dy: k.2, dAngle: k.3, shift: m.contains(.shift), option: m.contains(.option))
                        }.keyboardShortcut(k.0, modifiers: m)
                    }
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    func doneEditing() {
        if state.mode == .text { state.finishText() }
        state.setMode(nil)
    }

    func escape() {
        if emojiPickerOpen || stickerPickerOpen { emojiPickerOpen = false; stickerPickerOpen = false; return }
        if state.mode != nil { state.setMode(nil); return }
        if state.selected != nil { state.selected = nil; return }
        tryClose()
    }

    // MARK: save

    func save() {
        guard !isSaving else { return }
        if state.mode == .text { state.finishText() }
        let doc = state.exportDocument
        state.setMode(nil)
        state.selected = nil
        isSaving = true
        defer { isSaving = false }
        guard let r = MediaEditorExport.export(doc, background: state.background, caption: caption, isViewOnce: localViewOnce, isHighQuality: localHighQuality) else {
            tryClose()
            return
        }
        onDone(r)
    }
}

/// `MediaEditor__control`.
struct MediaEditorControl: View {
    let icon: String
    let label: String
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        SwiftUI.Button(action: action) {
            SignalIcon(icon, size: 20, color: AxoColor(disabled ? LegacyColor.gray45 : selected && !hovered ? RGBA(0, 0, 0) : RGBA(1, 1, 1)), mask: true)
                .frame(width: 32, height: 32)
                .background(hovered && !disabled ? MediaEditor.gray80 : selected ? AxoColor(RGBA(1, 1, 1)) : AxoColor(RGBA(0, 0, 0, 0)), in: RoundedRectangle(cornerRadius: 20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// `Slider` with `HueSlider`: a 280 × 8 hue gradient (4px corners, 7px start margin) and a
/// 22px handle in the current colour with a 7px white border.
struct HueSlider: View {
    let label: String
    @Binding var value: Double
    static let stops: [RGBA] = [RGBA(0, 0, 0)] + stride(from: 0, through: 315, by: 45).map { MediaEditorColor.hueColor(Double($0)) } + [RGBA(1, 1, 1)]

    var body: some View {
        let width: CGFloat = 280
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: Self.stops.map(\.swiftUIColor), startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 8)
            .overlay(alignment: .topLeading) {
                Circle().fill(MediaEditorColor.color(value).swiftUIColor)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 7))
                    .frame(width: 22, height: 22)
                    .offset(x: width * value / 100 - 11, y: -7)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(DragGesture(minimumDistance: 0).onChanged { e in value = min(100, max(0, 100 * e.location.x / width)) })
            .padding(.leading, 7)
            .focusable()
            .onKeyPress(.leftArrow) { value = max(0, value - 1); return .handled }
            .onKeyPress(.rightArrow) { value = min(100, value + 1); return .handled }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text("\(Int(value))"))
            .accessibilityAdjustableAction { d in value = d == .increment ? min(100, value + 1) : max(0, value - 1) }
    }
}

extension MediaEditorColor {
    /// hsl(h, 100%, 50%)
    static func hueColor(_ h: Double) -> RGBA {
        // color() maps the slider; invert its hue range for a plain hue.
        color(7 + h / 338 * 88)
    }
}

extension FunPanelStickers {
    /// The same panel reporting selections to `handler`.
    func onSelect(_ handler: @escaping (FunStickerItem) -> Void) -> FunPanelStickers {
        var p = self
        p.onSelectSticker = handler
        return p
    }
}
