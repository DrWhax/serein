// Port of ts/components/PreferencesInternal.dom.tsx: the internal-user page (message schema
// versions, call quality survey testing, a read-only SQL playground, megaphones, calling
// overrides, key transparency). The backup validation and donation receipt sections are left
// out with backups and donations.

import CoreText
import SignalI18n
import SwiftUI

/// The Internal page's calling and testing overrides (nil: the default).
public struct InternalSettings: Sendable, Hashable {
    public var cqsTestMode = false
    public var dredDuration: Int?
    public var callStatsIntervalSecs: Int?
    public var enableVp9Encode: Bool?
    public var enableVp9Decode: Bool?
    public var directMaxBitrate: Int?
    public var groupMaxBitrate: Int?
    public var isGroupSvcEnabled: Bool?
    public var groupSvcMode: String?
    public var groupSvcModeForScreenshare: String?
    public var sfuUrl: String?
    public init() {}
}

/// `StorageAccessType['keyTransparencySelfHealth']`
public enum KeyTransparencySelfHealth: Sendable { case ok, fail, intermittent }

public struct PreferencesInternal: View {
    public struct Actions {
        /// (schema version, message count) pairs.
        public var getMessageCountBySchemaVersion: () async -> [(Int, Int)] = { [] }
        /// A JSON sample of messages at a schema version.
        public var getMessageSampleForSchemaVersion: (Int) async -> String = { _ in "" }
        /// The query's rows as pretty-printed JSON.
        public var runReadOnlySqlQuery: (String) async -> String = { _ in "[]" }
        /// Shows the test megaphone; returns its description.
        public var addTestMegaphone: () -> String = { "" }
        public var deleteAllMegaphones: () async -> Int = { 0 }
        public var resetCallingOverrides: () -> Void = {}
        public var forceKeyTransparencyCheck: () async -> Void = {}
        public init() {}
    }

    /// `SVC_DEFAULT_MODE`, `SVC_DEFAULT_MODE_FOR_SCREENSHARE`
    public static let svcDefaultMode = "L3T3_KEY"
    public static let svcDefaultModeForScreenshare = "L1T3"

    @Binding var settings: InternalSettings
    let keyTransparencySelfHealth: KeyTransparencySelfHealth?
    let actions: Actions
    @State private var schemaCounts: [(Int, Int)]?
    @State private var schemaSample: (Int, String)?
    @State private var sqlInput = ""
    @State private var sqlResult: String?
    @State private var megaphoneResult: String?
    @State private var deletedMegaphones: Int?
    @State private var keyTransparencyRunning = false
    @State private var firstFocused = true
    @Environment(\.i18n) var i18n

    public init(settings: Binding<InternalSettings>, keyTransparencySelfHealth: KeyTransparencySelfHealth? = nil, actions: Actions = Actions()) {
        _settings = settings
        self.keyTransparencySelfHealth = keyTransparencySelfHealth
        self.actions = actions
    }

    /// `stripAndParseString`: the digits of `input`, or nil.
    static func digits(_ input: String) -> Int? {
        let d = input.filter(\.isASCII).filter(\.isNumber)
        return d.isEmpty ? nil : Int(d.prefix(18))
    }

    func intBinding(_ key: WritableKeyPath<InternalSettings, Int?>, transform: @escaping (Int?) -> Int? = { $0 }) -> Binding<String> {
        Binding(get: { settings[keyPath: key].map(String.init) ?? "" }, set: { settings[keyPath: key] = transform(Self.digits($0)) })
    }

    func stringBinding(_ key: WritableKeyPath<InternalSettings, String?>) -> Binding<String> {
        Binding(get: { settings[keyPath: key] ?? "" }, set: { settings[keyPath: key] = $0.isEmpty ? nil : $0 })
    }

    func boolBinding(_ key: WritableKeyPath<InternalSettings, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] ?? value }, set: { settings[keyPath: key] = $0 })
    }

    /// `AutoSizeTextArea` with the playground's monospace font.
    func textArea(_ value: Binding<String>, placeholder: String, readOnly: Bool = false) -> some View {
        Input(value: value, placeholder: placeholder, clearLabel: i18n("icu:cancel"), forceTextarea: true, readOnly: readOnly)
            .environment(\.inputTextStyle, CSSTextStyle(fontName: AxoFonts.monospaceName, size: 14, lineHeight: 20, letterSpacing: -0.08))
            .padding(.vertical, 16)                       // .Input__container margin-block
    }

    /// A textarea at its default 20 columns (the `--justify-end` one-third cells).
    func narrowTextArea(_ value: Binding<String>, placeholder: String) -> some View {
        textArea(value, placeholder: placeholder).frame(width: InternalFlowRow<EmptyView>.textareaWidth)
    }

    func button(_ label: String, _ variant: AxoButton.Variant, symbol: AxoSymbol.Name? = nil, pending: Bool = false,
                focused: Bool = false, action: @escaping () -> Void) -> some View {
        AxoButton.Root(label, variant: variant, size: .lg, symbol: symbol, pending: pending, autoFocus: focused) {
            firstFocused = false
            action()
        }
    }

    func label(_ text: String) -> some View { CSSText(text, style: LegacyType.body1(), color: .labelPrimary) }

    var keyTransparencySymbol: AxoSymbol.Name? {
        switch keyTransparencySelfHealth {
        case nil: nil
        case .ok: "check-circle-fill"
        case .fail, .intermittent: "error-circle-fill"
        }
    }

    public var body: some View {
        PreferencesContent(title: i18n("icu:Preferences__button--internal")) {
            SettingsRow(title: "Message schema versions") {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Check message schema versions")
                    // Radix-less upstream: the pane's first control takes focus on open.
                    button("Fetch data", .strongSecondary, focused: firstFocused) {
                        Task {
                            schemaCounts = await actions.getMessageCountBySchemaVersion()
                            schemaSample = nil
                        }
                    }
                    .padding(.leading, 5)                 // .Preferences__flow-button
                }
                if let schemaCounts { schemaTable(schemaCounts) }
            }
            SettingsRow(title: "Call Quality Survey Testing") {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("CQS testing: disable cooldown and always show for calls under 30s")
                    AxoSwitch.Root(checked: $settings.cqsTestMode)
                }
            }
            SettingsRow(title: "Readonly SQL Playground") {
                VStack(alignment: .leading, spacing: 0) {
                    textArea($sqlInput, placeholder: "SELECT * FROM items")
                    button("Run Query", .strongDestructive) {
                        let query = sqlInput
                        Task { sqlResult = await actions.runReadOnlySqlQuery(query) }
                    }
                    if let sqlResult { textArea(.constant(sqlResult), placeholder: "", readOnly: true) }
                }
                .padding(.vertical, 4).padding(.horizontal, 24)
            }
            SettingsRow(title: "Megaphones") {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Show a test megaphone in memory. Disappears on restart.")
                    button("Show megaphone", .strongSecondary) {
                        megaphoneResult = "Megaphone shown. Go to Chats tab to view.\n" + actions.addTestMegaphone()
                    }
                    .padding(.leading, 5)
                }
                if let megaphoneResult { textArea(.constant(megaphoneResult), placeholder: "", readOnly: true).padding(.horizontal, 24) }
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Delete local records of remote megaphones")
                    button("Delete", .strongDestructive) { Task { deletedMegaphones = await actions.deleteAllMegaphones() } }
                        .padding(.leading, 5)
                }
                if let deletedMegaphones { textArea(.constant("Deleted: \(deletedMegaphones)"), placeholder: "", readOnly: true) }
            }
            SettingsRow(title: "Calling General") {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Clear custom calling preferences")
                    button("Clear", .strongDestructive, action: actions.resetCallingOverrides)
                }
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("DRED Duration (0 - 100)")
                    narrowTextArea(intBinding(\.dredDuration) { $0.map { min(100, $0) } }, placeholder: "0 - 100")
                }
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Stats Interval Seconds")
                    narrowTextArea(intBinding(\.callStatsIntervalSecs) { $0.map { max(1, $0) } }, placeholder: "Default")
                }
            }
            SettingsRow(title: "Direct Calls") {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Enable VP9 Encode")
                    AxoSwitch.Root(checked: boolBinding(\.enableVp9Encode, default: true))
                }
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Enable VP9 Decode")
                    AxoSwitch.Root(checked: boolBinding(\.enableVp9Decode, default: true))
                }
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Max bitrate")
                    narrowTextArea(intBinding(\.directMaxBitrate), placeholder: "Default")
                }
            }
            SettingsRow(title: "Group/Adhoc Calls") {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Enable SVC")
                    AxoSwitch.Root(checked: boolBinding(\.isGroupSvcEnabled, default: false))
                }
                InternalFlowRow(.oneThird, .twoThirds) {
                    label("SVC Mode")
                    textArea(stringBinding(\.groupSvcMode), placeholder: Self.svcDefaultMode)
                }
                InternalFlowRow(.oneThird, .twoThirds) {
                    label("SVC mode for screenshare")
                    textArea(stringBinding(\.groupSvcModeForScreenshare), placeholder: Self.svcDefaultModeForScreenshare)
                }
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Max bitrate")
                    narrowTextArea(intBinding(\.groupMaxBitrate), placeholder: "Default")
                }
                InternalFlowRow(.oneThird, .twoThirds) {
                    label("SFU URL")
                    textArea(stringBinding(\.sfuUrl), placeholder: "https://sfu.voip.signal.org")
                }
            }
            SettingsRow(title: "Key Transparency", isLast: true) {
                InternalFlowRow(.twoThirds, .oneThirdEnd) {
                    label("Force Self Check")
                    button("Check", .strongSecondary, symbol: keyTransparencySymbol, pending: keyTransparencyRunning) {
                        keyTransparencyRunning = true
                        Task {
                            await actions.forceKeyTransparencyCheck()
                            keyTransparencyRunning = false
                        }
                    }
                }
            }
        }
    }

    /// `.Preferences--internal--result`: the schema versions with a Sample button each.
    func schemaTable(_ rows: [(Int, Int)]) -> some View {
        let mono = CSSTextStyle(fontName: AxoFonts.monospaceName, size: 13, lineHeight: 18)
        let bold = CSSTextStyle(fontName: AxoFonts.monospaceName(weight: 700, italic: false), size: 13, lineHeight: 18)
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                CSSText("Schema version", style: bold, color: .labelPrimary)
                CSSText("# Messages", style: bold, color: .labelPrimary)
                Color.clear.frame(width: 0, height: 0)
            }
            ForEach(rows, id: \.0) { version, count in
                GridRow {
                    CSSText(String(version), style: mono, color: .labelPrimary)
                    CSSText(String(count), style: mono, color: .labelPrimary)
                    SwiftUI.Button("Sample") {
                        Task { schemaSample = (version, await actions.getMessageSampleForSchemaVersion(version)) }
                    }
                }
                if let schemaSample, schemaSample.0 == version {
                    GridRow {
                        CSSText(schemaSample.1, style: mono, color: .labelPrimary)
                            .padding(4)
                            .background(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha06))
                            .gridCellColumns(3)
                    }
                }
            }
        }
        .padding(.leading, 48).padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `FlowingSettingsControl` with two inline-block cells (`__two-thirds-flow` 66% /
/// `__one-third-flow` 33%, vertical-align middle) inside padding 4px 24px.
struct InternalFlowRow<Content: View>: View {
    enum Cell {
        case oneThird, twoThirds, oneThirdEnd
        var fraction: CGFloat { self == .twoThirds ? 0.66 : 0.33 }
    }
    let cells: [Cell]
    let content: Content

    /// A textarea's default 20 columns of Menlo 14px, plus padding 12px and border 2px.
    static var textareaWidth: CGFloat {
        20 * CSSTextLayout.make("0", CSSTextStyle(fontName: AxoFonts.monospaceName, size: 14, lineHeight: 20), wrap: .nowrap, maxWidth: nil).width + 28
    }

    init(_ first: Cell, _ second: Cell, @ViewBuilder content: () -> Content) {
        cells = [first, second]
        self.content = content()
    }

    var body: some View {
        FractionRow(cells: cells) { content }
            .padding(.vertical, 4)
            .padding(.horizontal, 24)
    }

    /// Children at fractions of the width as `vertical-align: middle` inline-blocks: each
    /// centred half an x-height above the baseline of a line whose strut is Inter 14px/20px;
    /// `--justify-end` cells end-aligned.
    struct FractionRow: Layout {
        let cells: [Cell]

        static var strut: (top: CGFloat, bottom: CGFloat, middle: CGFloat) { internalFlowStrut }

        func heights(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
            zip(subviews, cells).map { $0.sizeThatFits(ProposedViewSize(width: width * $1.fraction, height: nil)) }
        }

        func lineTop(_ sizes: [CGSize]) -> (top: CGFloat, height: CGFloat) {
            let s = Self.strut
            let top = min(s.top, sizes.map { s.middle - $0.height / 2 }.min() ?? s.top)
            let bottom = max(s.bottom, sizes.map { s.middle + $0.height / 2 }.max() ?? s.bottom)
            return (top, bottom - top)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = proposal.width ?? 0
            return CGSize(width: w, height: lineTop(heights(subviews, width: w)).height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let sizes = heights(subviews, width: bounds.width)
            let line = lineTop(sizes)
            var x = bounds.minX
            for ((s, c), size) in zip(zip(subviews, cells), sizes) {
                let cellWidth = bounds.width * c.fraction
                let w = min(size.width, cellWidth)
                let dx = c == .oneThirdEnd ? cellWidth - w : 0
                let y = Self.strut.middle - size.height / 2 - line.top
                s.place(at: CGPoint(x: x + dx, y: bounds.minY + y), proposal: ProposedViewSize(width: w, height: size.height))
                x += cellWidth
            }
        }
    }
}

/// The strut's top and bottom and the middle line, relative to the baseline (y down).
private let internalFlowStrut: (top: CGFloat, bottom: CGFloat, middle: CGFloat) = {
    let font = LegacyType.body1().ctFont
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    let halfLeading = (20 - ascent - descent) / 2
    return (-(ascent + halfLeading), descent + halfLeading, -CTFontGetXHeight(font) / 2)
}()
