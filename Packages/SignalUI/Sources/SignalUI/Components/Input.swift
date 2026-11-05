// Port of ts/components/Input.dom.tsx + stylesheets/components/Input.scss: the legacy text
// input (or 1-row textarea when `expandable` / `forceTextarea`) with an optional icon, clear
// button and remaining-character count, limited to `maxLengthCount` graphemes and
// `maxByteCount` UTF-8 bytes.
//
// Text entry follows AxoBaseField: ImageRenderer cannot draw TextField, and SwiftUI Text does
// not lay out like Chromium, so the resting control (value or placeholder) is drawn with
// CSSText exactly as Chromium draws an unfocused <input>; a click or keyboard focus puts a
// plain TextField over the same frame until focus leaves. Under axoStaticRendering the
// control stays at rest. Chromium's ::placeholder is the input's colour at 50% alpha
// (Input.scss's `&:placeholder` never matches).
// `isLarge` (upstream: the textarea's scrollHeight exceeds its height) is when the value wraps
// to more than one line; the textarea is then 280px tall and the count moves to the corner.

import SwiftUI

public struct Input: View {
    @Binding var value: String
    let placeholder: String
    let disabled: Bool
    let disableSpellcheck: Bool
    let expandable: Bool
    let forceTextarea: Bool
    let hasClearButton: Bool
    let shouldShowClearButton: Bool
    let maxByteCount: Int
    let maxLengthCount: Int
    let whenToShowRemainingCount: Int
    let whenToWarnRemainingCount: Int
    let readOnly: Bool
    let autoFocus: Bool
    /// i18n: `icu:cancel` (the clear button's label)
    let clearLabel: String
    let icon: AnyView?
    let children: AnyView?
    let onEnter: (() -> Void)?
    @State private var editing = false
    @FocusState private var liveFocused: Bool
    @FocusState private var restingFocused: Bool
    @State private var width: CGFloat = 0
    @Environment(\.axoStaticRendering) var isStatic

    public init(value: Binding<String>, placeholder: String, clearLabel: String, disabled: Bool = false, disableSpellcheck: Bool = false,
                expandable: Bool = false, forceTextarea: Bool = false, hasClearButton: Bool = false, shouldShowClearButton: Bool = false,
                maxByteCount: Int = 0, maxLengthCount: Int = 0, whenToShowRemainingCount: Int = .max, whenToWarnRemainingCount: Int = .max,
                readOnly: Bool = false, autoFocus: Bool = false, icon: AnyView? = nil, children: AnyView? = nil, onEnter: (() -> Void)? = nil) {
        _value = value
        self.placeholder = placeholder
        self.clearLabel = clearLabel
        self.disabled = disabled
        self.disableSpellcheck = disableSpellcheck
        self.expandable = expandable
        self.forceTextarea = forceTextarea
        self.hasClearButton = hasClearButton
        self.shouldShowClearButton = shouldShowClearButton
        self.maxByteCount = maxByteCount
        self.maxLengthCount = maxLengthCount
        self.whenToShowRemainingCount = whenToShowRemainingCount
        self.whenToWarnRemainingCount = whenToWarnRemainingCount
        self.readOnly = readOnly
        self.autoFocus = autoFocus
        self.icon = icon
        self.children = children
        self.onEnter = onEnter
    }

    static var textStyle: CSSTextStyle { LegacyType.body1() }
    /// The input's font (a caller's `.Input__input` font-family override).
    @Environment(\.inputTextStyle) var overrideStyle
    var textStyle: CSSTextStyle { overrideStyle ?? Self.textStyle }

    var isTextarea: Bool { expandable || forceTextarea }
    var interactive: Bool { !disabled && !readOnly && !isStatic }
    var lengthCount: Int { maxLengthCount > 0 ? value.count : -1 }
    var showsClear: Bool { hasClearButton && (shouldShowClearButton || !value.isEmpty) }
    var showsCount: Bool { lengthCount >= 0 && lengthCount >= whenToShowRemainingCount }
    var focusedWithin: Bool { editing && interactive }

    /// `isLarge`: an expandable value that no longer fits on one line.
    var isLarge: Bool {
        expandable && width > 0 && !value.isEmpty
            && CSSTextLayout.make(value, textStyle, wrap: .wrap, maxWidth: width).lines.count > 1
    }

    /// The text colour: `.Input__input` (black / gray-05), whatever the container's state.
    static var textColor: AxoColor { AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05) }
    static var placeholderColor: AxoColor {
        AxoColor(light: RGBA(0, 0, 0, 0.5), dark: RGBA(LegacyColor.gray05.r, LegacyColor.gray05.g, LegacyColor.gray05.b, 0.5))
    }

    var background: AxoColor {
        disabled ? AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray95) : AxoColor(light: LegacyColor.white, dark: LegacyColor.gray80)
    }

    var borderColor: AxoColor {
        // Snapshots show an autoFocus input as focused (its caret aside).
        if focusedWithin || (isStatic && autoFocus) { return AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.ultramarineLight) }
        return disabled ? AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray60) : AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray45)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let large = isLarge
        HStack(alignment: .top, spacing: 0) {
            if let icon {
                icon.frame(width: 32, height: 32).padding(.trailing, 8)       // .Input__icon
            }
            textbox(large: large)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // .Input__controls: flex, justify-end, items-center, shrink-0, min-height 32px
            HStack(spacing: 0) {
                if !large, showsCount { remainingCount }
                if showsClear { clearButton }
                if let children { children }
            }
            .frame(minHeight: 32)
            .fixedSize()
        }
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))     // border 2px + padding 2px 12px
        .overlay(alignment: .bottomTrailing) {
            if large, showsCount { remainingCount.padding(14) }               // .Input__remaining-count--large (margin 12px inside the border)
        }
        .background(shape.fill(background))
        .overlay(shape.strokeBorder(borderColor, lineWidth: 2))
        .accessibilityElement(children: .contain)
    }

    /// `.Input__input`: the input (32px, text centred) or the 1-row textarea (margin-top 6px).
    @ViewBuilder func textbox(large: Bool) -> some View {
        let showPlaceholder = value.isEmpty
        ZStack(alignment: .topLeading) {
            CSSText(showPlaceholder ? placeholder : value, style: textStyle, wrap: isTextarea ? .wrap : .nowrap,
                    color: showPlaceholder ? Self.placeholderColor : Self.textColor)
                .opacity(focusedWithin && !showPlaceholder ? 0 : 1)
            if focusedWithin { live }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: large ? 280 : 32, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { begin() }
        .focusable(interactive && !focusedWithin)
        .focused($restingFocused)
        .focusEffectDisabled()
        .onChange(of: restingFocused) { _, focused in if focused { begin() } }
        .onAppear { if autoFocus { begin() } }
        .accessibilityElement()
        .accessibilityLabel(placeholder)
        .accessibilityValue(value)
    }

    var live: some View {
        TextField("", text: Binding(get: { value }, set: { update($0) }), axis: isTextarea ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(AxoFonts.inter(size: 14))
            .foregroundStyle(Self.textColor)
            .autocorrectionDisabled(disableSpellcheck)
            .focused($liveFocused)
            .onAppear { liveFocused = true }
            .onChange(of: liveFocused) { _, focused in if !focused { editing = false } }
            .onSubmit { onEnter?() }
    }

    func begin() {
        guard interactive else { return }
        editing = true
    }

    /// handleChange / handlePaste: an edit that exceeds a limit is truncated to fit (a typed
    /// character that does not fit is dropped).
    func update(_ new: String) {
        let old = value
        var candidate = new
        let overLength = maxLengthCount > 0 && candidate.count > maxLengthCount
        let overBytes = maxByteCount > 0 && candidate.utf8.count > maxByteCount
        if overLength || overBytes {
            // Keep the common prefix and suffix, truncate the inserted middle.
            let prefix = old.commonPrefix(with: new)
            let rest = new.dropFirst(prefix.count)
            let oldRest = old.dropFirst(prefix.count)
            var suffixCount = 0
            while suffixCount < min(rest.count, oldRest.count), rest.dropLast(suffixCount).last == oldRest.dropLast(suffixCount).last {
                suffixCount += 1
            }
            let suffix = String(rest.suffix(suffixCount))
            var inserted = String(rest.dropLast(suffixCount))
            func fits(_ s: String) -> Bool {
                (maxLengthCount == 0 || s.count <= maxLengthCount) && (maxByteCount == 0 || s.utf8.count <= maxByteCount)
            }
            while !inserted.isEmpty && !fits(prefix + inserted + suffix) { inserted.removeLast() }
            candidate = prefix + inserted + suffix
            if !fits(candidate) { candidate = old }
        }
        value = candidate
    }

    /// `.Input__remaining-count` (font-subtitle, gray-45; `--warn`: accent-red)
    var remainingCount: some View {
        CSSText(String(maxLengthCount - lengthCount), style: LegacyType.subtitle(), wrap: .nowrap,
                color: lengthCount >= whenToWarnRemainingCount ? AxoColor(LegacyColor.accentRed) : AxoColor(LegacyColor.gray45))
    }

    /// `.Input__clear-icon`: 18×18, x.svg in gray-60 / gray-25.
    var clearButton: some View {
        SwiftUI.Button { value = "" } label: {
            LegacyIcon.Mask(.x, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(clearLabel)
    }
}

extension EnvironmentValues {
    /// Replaces the legacy Input's body-1 Inter (e.g. `$monospace` in the Internal page).
    @Entry public var inputTextStyle: CSSTextStyle? = nil
}
