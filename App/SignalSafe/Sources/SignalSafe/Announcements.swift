// Server alerts and announcements in the app: the idle-primary-device banners in the chat list
// (`ServerAlerts`, `getServerAlertToShow`) and the critical dialog on upstream's schedule; the
// release-notes fetcher run when due (checked hourly); and the remote megaphones, shown in the
// banner slot below the toasts after the username onboarding one.

import AppKit
import SignalCore
import SignalUI
import SwiftUI

extension SignalSession {
    /// Starts the alert and megaphone observations and the fetcher (once per session).
    func startAnnouncements(_ session: SignalClient.Session, database db: SignalDatabase) {
        announcementsTask?.cancel()
        let store = session.attachmentStore
        let service = ReleaseNotesService(account: session.account, database: db, store: store, media: media)
        announcementsTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { for try await alerts in db.serverAlertUpdates() { await self?.serverAlertsChanged(alerts) } } catch {}
                }
                group.addTask {
                    do { for try await visible in db.megaphoneUpdates(store: store) { await MainActor.run { self?.megaphones = visible } } } catch {}
                }
                group.addTask {
                    do { for try await due in db.keyTransparencyErrorUpdates() { await MainActor.run { self?.keyTransparencyErrorOpen = due } } } catch {}
                }
                group.addTask {
                    // `initMegaphoneCheckService` / the fetcher's timer: hourly, each runs when due.
                    while !Task.isCancelled {
                        await service.runIfDue(locales: Self.releaseNoteLocales)
                        try? await db.checkMegaphones(store: store)
                        try? await Task.sleep(for: .seconds(3600))
                    }
                }
            }
        }
    }

    /// `#getLocales`: ours, its language, then English, as `ll_rr` (the manifest's file names).
    nonisolated static var releaseNoteLocales: [String] {
        let locale = AppLanguage.resolvedLocale.lowercased().replacingOccurrences(of: "-", with: "_")
        let language = String(locale.split(separator: "_").first ?? Substring(locale))
        var out: [String] = []
        for l in [locale, language, "en"] where !out.contains(l) { out.append(l) }
        return out
    }

    func serverAlertsChanged(_ alerts: [SignalCore.ServerAlert: ServerAlertInfo]) {
        serverAlerts = alerts
        scheduleCriticalIdleModal()
    }

    /// `maybeShowCriticalIdlePrimaryDeviceModal`: the dialog when it is due.
    func scheduleCriticalIdleModal() {
        criticalModalTask?.cancel()
        guard let due = ServerAlerts.criticalModalDue(serverAlerts, now: Self.nowMs) else { return }
        let wait = max(0, due - Self.nowMs)
        criticalModalTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled else { return }
            self?.criticalIdleModalOpen = true
        }
    }

    /// `onCriticalIdlePrimaryDeviceModalDismissed`
    func dismissCriticalIdleModal() {
        criticalIdleModalOpen = false
        guard let db = clientDatabase else { return }
        Task { try? await db.dismissCriticalIdlePrimaryDeviceModal() }
    }

    /// SmartKeyTransparencyErrorDialog: closed, or submitted (Signal's support form opens; no
    /// debug log, which Serein does not keep).
    func closeKeyTransparencyError(openSupport: Bool) {
        keyTransparencyErrorOpen = false
        if openSupport, let url = URL(string: AppDelegate.supportURL(locale: AppLanguage.resolvedLocale.lowercased())) { NSWorkspace.shared.open(url) }
        guard let db = clientDatabase else { return }
        Task { try? await db.clearKeyTransparencyError() }
    }

    /// The chat list's server-alert banner (`ServerAlerts`), if one is to be shown.
    func serverAlertBanner(_ breakpoint: WidthBreakpoint) -> AnyView? {
        switch ServerAlerts.toShow(serverAlerts, now: Self.nowMs) {
        case .criticalIdlePrimaryDevice: AnyView(CriticalIdlePrimaryDeviceDialog(containerWidthBreakpoint: breakpoint))
        case .idlePrimaryDevice:
            AnyView(WarningIdlePrimaryDeviceDialog(containerWidthBreakpoint: breakpoint, handleClose: { [weak self] in
                guard let db = self?.clientDatabase else { return }
                Task { try? await db.dismissIdlePrimaryDeviceBanner() }
            }))
        case nil: nil
        }
    }

    /// The first visible remote megaphone (`RemoteMegaphone`), finish or snooze on its buttons.
    func remoteMegaphoneView(isFullSize: Bool, onClickNarrowMegaphone: @escaping () -> Void = {}) -> AnyView? {
        guard let m = megaphones.first else { return nil }
        let image = m.image.flatMap { avatarImage($0) }
        return AnyView(RemoteMegaphone(remoteMegaphoneId: m.id, title: m.title, body: m.body, image: image, primaryCtaId: m.primaryCtaId,
                                       secondaryCtaId: m.secondaryCtaId, primaryCtaText: m.primaryCtaText, secondaryCtaText: m.secondaryCtaText,
                                       isFullSize: isFullSize, onClickNarrowMegaphone: onClickNarrowMegaphone, onInteractWithMegaphone: { [weak self] id, cta in
                                           guard let db = self?.clientDatabase else { return }
                                           Task { try? await db.interactWithMegaphone(id: id, ctaId: cta) }
                                       }))
    }

    nonisolated static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
