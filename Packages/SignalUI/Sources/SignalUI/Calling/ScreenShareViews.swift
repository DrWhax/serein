// Ports of ts/components/CallingSelectPresentingSourcesModal.dom.tsx (pick a screen or
// window: two 4-column grids of thumbnail cards), NeedsScreenRecordingPermissionsModal.dom.tsx
// (the macOS screen-recording permission alert) and CallingScreenSharingController.dom.tsx
// with its window (app/main.main.ts showScreenShareWindow: 480×44, frameless, always on top,
// centred 24px below the top of the primary display, #2e2e2e) — "Sharing <window>" and "Stop
// sharing" while presenting.

import AppKit
import SignalI18n
import SwiftUI

public struct CallingSelectPresentingSourcesModal: View {
    let sources: [PresentableSource]
    let onSourceSelect: (String) -> Void
    let onCancel: () -> Void
    @State var selected: String?
    @Environment(\.i18n) var i18n

    public init(sources: [PresentableSource], onSourceSelect: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.sources = sources
        self.onSourceSelect = onSourceSelect
        self.onCancel = onCancel
    }

    public var body: some View {
        let screens = sources.filter(\.isScreen), windows = sources.filter { !$0.isScreen }
        AxoDialog.Content(size: .lg) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:calling__SelectPresentingSourcesModal--title"))
                AxoDialog.Close(action: onCancel)
            }
            // The capture shows the body's classic 11px scrollbar gutters.
            AxoDialog.Body(gutter: 11) {
                VStack(alignment: .leading, spacing: 8) {
                    if !screens.isEmpty { grid(i18n("icu:calling__SelectPresentingSourcesModal--entireScreen"), screens) }
                    if !windows.isEmpty { grid(i18n("icu:calling__SelectPresentingSourcesModal--window"), windows) }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onCancel)
                    AxoDialog.Action(i18n("icu:calling__SelectPresentingSourcesModal--confirm"), variant: .strongPrimary, disabled: selected == nil) {
                        if let selected { onSourceSelect(selected) }
                    }
                }
            }
        }
    }

    /// `SourceGrid`: an h4 (type-title-small, mb-1) over `grid grid-cols-4 gap-2`.
    func grid(_ label: String, _ items: [PresentableSource]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CSSText(label, type: .titleSmall, color: .labelSecondary).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), alignment: .leading, spacing: 8) {
                ForEach(items) { s in
                    SourceCard(source: s, isSelected: selected == s.id) { selected = s.id }
                }
            }
        }
    }
}

/// `Source`: curved-lg p-1 card (surface-card, accent when pressed/selected), the thumbnail
/// (curved-md, object-cover) and below it (mt-1) the app icon (size-4, me-1) and the name.
struct SourceCard: View {
    let source: PresentableSource
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                SourceThumbnail(image: source.thumbnail, size: source.thumbnailSize)
                    .clipShape(SuperellipseRect.curved(6))
                HStack(spacing: 4) {
                    if let icon = ScreenShareCapture.icon(bundleId: source.appBundleId) {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                    }
                    CSSText(source.name, type: .bodySmall, wrap: .truncate, color: isSelected ? .labelPrimaryOncolor : .labelPrimary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(4)
            .background(SuperellipseRect.curved(8).fill(isSelected ? AxoColor.fillAccent : AxoColor.surfaceCard))
            .axoShadow(.shadowElevation0, in: SuperellipseRect.curved(8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// `SourceThumbnail` in its `AspectRatio` box (width = the thumbnail's, at most the card's;
/// its aspect ratio): the image object-cover, or the error triangle when capture failed.
struct SourceThumbnail: View {
    let image: RGBAImage?
    let size: CGSize

    var body: some View {
        AspectBox(width: size.width, ratio: size.height / max(1, size.width)) {
            if let image {
                PixelImage(image, fit: .cover)
            } else {
                AxoSymbol.Icon("error-triangle", size: 24, label: nil).cssTextColor(.labelPrimary)
            }
        }
    }
}

/// `width: <w>; max-width: 100%; aspect-ratio`: the height snapped down to the 2x device-pixel
/// grid as Chromium paints it (SwiftUI would round 99.77 up to 100 and shift the row below).
struct AspectBox: Layout {
    let width: CGFloat
    let ratio: CGFloat

    func size(_ proposal: ProposedViewSize) -> CGSize {
        let w = min(width, proposal.width ?? width)
        return CGSize(width: w, height: (w * ratio * 2).rounded(.down) / 2)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = size(proposal)
        return CGSize(width: proposal.width ?? s.width, height: s.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = size(ProposedViewSize(width: bounds.width, height: nil))
        for v in subviews {
            v.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(s))
        }
    }
}

public struct NeedsScreenRecordingPermissionsModal: View {
    let openSystemPreferencesAction: () -> Void
    let toggleScreenRecordingPermissionsDialog: (Bool) -> Void
    @Environment(\.i18n) var i18n

    public init(openSystemPreferencesAction: @escaping () -> Void = { ScreenRecordingPermission.openSystemSettings() },
                toggleScreenRecordingPermissionsDialog: @escaping (Bool) -> Void) {
        self.openSystemPreferencesAction = openSystemPreferencesAction
        self.toggleScreenRecordingPermissionsDialog = toggleScreenRecordingPermissionsDialog
    }

    static var style: CSSTextStyle { CSSTextStyle(AxoType.bodyMedium) }

    /// `<ol class="list-inside list-decimal">` item: the marker is inline, so wrapped lines
    /// start under it (the text's first line leaves the marker's width free).
    func item(_ n: Int, _ text: String) -> some View {
        ZStack(alignment: .topLeading) {
            CSSText("\(n).", style: MediaPermissionsModal.markerStyle, wrap: .nowrap, color: .labelPrimary)
            CSSText(runs: [.inlineBlock("", CSSInlineBlock(paddingInline: MediaPermissionsModal.markerWidth(n) / 2)), CSSTextRun(text)], style: Self.style,
                    color: .labelPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(i18n("icu:calling__presenting--permission-title"))
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(i18n("icu:calling__presenting--macos-permission-description"), style: Self.style, color: .labelPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        item(1, i18n("icu:calling__presenting--permission-instruction-step1"))
                        item(2, i18n("icu:calling__presenting--permission-instruction-step2"))
                        item(3, i18n("icu:calling__presenting--permission-instruction-step3"))
                    }
                }
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Cancel(i18n("icu:calling__presenting--permission-cancel")) { toggleScreenRecordingPermissionsDialog(false) }
                AxoAlertDialog.Action(i18n("icu:calling__presenting--permission-open"), variant: .strongPrimary) {
                    openSystemPreferencesAction()
                    toggleScreenRecordingPermissionsDialog(false)
                }
            }
        }
    }
}

/// `ScreenShareStatus`
public enum ScreenShareStatus: String, Sendable { case connected = "Connected", reconnecting = "Reconnecting", disconnected = "Disconnected" }

public struct CallingScreenSharingController: View {
    let status: ScreenShareStatus
    let presentedSourceName: String?
    let onStopSharing: () -> Void
    let onCloseController: () -> Void
    /// The SCSS sizes are in vw / vh: of the 480×44 window by default.
    let viewport: CGSize
    @Environment(\.i18n) var i18n

    public init(status: ScreenShareStatus, presentedSourceName: String?, viewport: CGSize = CGSize(width: 480, height: 44),
                onStopSharing: @escaping () -> Void, onCloseController: @escaping () -> Void) {
        self.status = status
        self.presentedSourceName = presentedSourceName
        self.viewport = viewport
        self.onStopSharing = onStopSharing
        self.onCloseController = onCloseController
    }

    var text: String {
        if status == .reconnecting { return i18n("icu:calling__presenting--reconnecting") }
        if let name = presentedSourceName { return i18n("icu:calling__presenting--info", ["window": .string(name)]) }
        return i18n("icu:calling__presenting--info--unknown")
    }

    public var body: some View {
        let vw = viewport.width / 100, vh = viewport.height / 100
        HStack(spacing: 0) {
            // width: 73vw, shrinking in the flex row; nowrap + ellipsis.
            CSSText(text, style: LegacyType.body2(), wrap: .truncate, color: .labelPrimary)
                .frame(maxWidth: 73 * vw, alignment: .leading)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                LegacyButton(i18n("icu:calling__presenting--stop"), variant: .destructive,
                             overrides: .init(paddingBlock: 0, paddingInline: 3.5 * vw, height: 82 * vh), action: onStopSharing)
                Button(action: onCloseController) {
                    LegacyIcon.Mask(.x, color: AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray25))
                        .frame(width: 4.5 * vw, height: 45.5 * vh)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:close"))
                .padding(.leading, 2.5 * vw)
            }
            .fixedSize()
            .padding(.leading, 1.25 * vw)
        }
        .padding(.vertical, 9 * vh)
        .padding(.horizontal, 3.3 * vw)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The floating "presenting" controller window. It is left out of screen captures
/// (`sharingType = .none`), so sharing the screen never shows it to the call.
@MainActor
public final class ScreenShareControllerWindow {
    var panel: NSPanel?

    public init() {}

    public func show(status: ScreenShareStatus, sourceName: String?, i18n: Localizer, onStop: @escaping () -> Void) {
        let view = CallingScreenSharingController(status: status, presentedSourceName: sourceName, onStopSharing: onStop,
                                                  onCloseController: { [weak self] in self?.close() })
            .frame(width: 480, height: 44)
            .background(Color(red: 0x2e / 255, green: 0x2e / 255, blue: 0x2e / 255))
            .environment(\.colorScheme, .dark)
            .environment(\.i18n, i18n)
        if let panel {
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            return
        }
        let width: CGFloat = 480, height: CGFloat = 44
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: frame.minX + (frame.width / 2 - width / 2).rounded(.down), y: frame.maxY - 24 - height, width: width, height: height)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = NSColor(red: 0x2e / 255, green: 0x2e / 255, blue: 0x2e / 255, alpha: 1)
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        p.orderFrontRegardless()
        panel = p
    }

    public func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
