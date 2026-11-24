// Server alerts (ts/util/handleServerAlerts.preload.ts, ts/types/ServerAlert.std.ts): the chat
// server tells a linked device, when it connects, that the primary device has been idle
// (`idle-primary-device`) or idle long enough to put the account at risk
// (`critical-idle-primary-device`). Kept as upstream's `serverAlerts` item: each alert with
// when it first came, when its banner was dismissed and when its dialog last was; an alert the
// server stops sending is dropped.

import Foundation
import GRDB

/// `ServerAlert`
public enum ServerAlert: String, Codable, Sendable, CaseIterable {
    case criticalIdlePrimaryDevice = "critical-idle-primary-device"
    case idlePrimaryDevice = "idle-primary-device"
}

/// One alert's record (`ServerAlertsType[alert]`).
public struct ServerAlertInfo: Codable, Sendable, Equatable {
    public var firstReceivedAt: Int64
    /// The idle banner's close (it stays away for a week).
    public var dismissedAt: Int64?
    /// The critical dialog's last close (it comes back a day later).
    public var modalLastDismissedAt: Int64?
}

public enum ServerAlerts {
    static let item = "serverAlerts"
    static let day: Int64 = 86_400_000
    static let week: Int64 = 7 * day

    /// `parseServerAlertsFromHeader`: comma-separated names, case-insensitive; unknown ones dropped.
    static func parse(_ values: [String]) -> [ServerAlert] {
        values.flatMap { $0.split(separator: ",") }
            .compactMap { ServerAlert(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    public static func current(_ db: Database) throws -> [ServerAlert: ServerAlertInfo] {
        let stored = try Items.get(db, item, as: [String: ServerAlertInfo].self) ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in ServerAlert(rawValue: k).map { ($0, v) } })
    }

    static func save(_ db: Database, _ alerts: [ServerAlert: ServerAlertInfo]) throws {
        try Items.set(db, item, Dictionary(uniqueKeysWithValues: alerts.map { ($0.key.rawValue, $0.value) }))
    }

    /// `handleServerAlerts`: the alerts the server sent now; ones seen before keep their record.
    static func received(_ db: Database, _ alerts: [ServerAlert], now: Int64) throws {
        let existing = try current(db)
        var next: [ServerAlert: ServerAlertInfo] = [:]
        for alert in alerts { next[alert] = existing[alert] ?? ServerAlertInfo(firstReceivedAt: now) }
        if next != existing { try save(db, next) }
    }

    /// `getServerAlertToShow`: the critical alert, else the idle one unless dismissed within a week.
    public static func toShow(_ alerts: [ServerAlert: ServerAlertInfo], now: Int64) -> ServerAlert? {
        if alerts[.criticalIdlePrimaryDevice] != nil { return .criticalIdlePrimaryDevice }
        if let idle = alerts[.idlePrimaryDevice], idle.dismissedAt.map({ now - $0 >= week }) ?? true { return .idlePrimaryDevice }
        return nil
    }

    /// `maybeShowCriticalIdlePrimaryDeviceModal`: when the critical dialog is due (three days
    /// after the alert first came; then at once if never dismissed, else a day after the last
    /// dismissal). nil without the alert.
    public static func criticalModalDue(_ alerts: [ServerAlert: ServerAlertInfo], now: Int64) -> Int64? {
        guard let info = alerts[.criticalIdlePrimaryDevice] else { return nil }
        if now - info.firstReceivedAt < 3 * day { return info.firstReceivedAt + 3 * day }
        guard let dismissed = info.modalLastDismissedAt else { return now }
        return dismissed + day
    }

    /// The idle banner was closed.
    public static func dismissIdleBanner(_ db: Database, now: Int64) throws {
        var alerts = try current(db)
        guard alerts[.idlePrimaryDevice] != nil else { return }
        alerts[.idlePrimaryDevice]?.dismissedAt = now
        try save(db, alerts)
    }

    /// `onCriticalIdlePrimaryDeviceModalDismissed`
    public static func dismissCriticalModal(_ db: Database, now: Int64) throws {
        var alerts = try current(db)
        guard alerts[.criticalIdlePrimaryDevice] != nil else { return }
        alerts[.criticalIdlePrimaryDevice]?.modalLastDismissedAt = now
        try save(db, alerts)
    }
}

extension SignalDatabase {
    public func serverAlertUpdates() -> AsyncThrowingStream<[ServerAlert: ServerAlertInfo], Error> { observe(ServerAlerts.current) }

    public func dismissIdlePrimaryDeviceBanner() async throws {
        try await pool.write { try ServerAlerts.dismissIdleBanner($0, now: MessageStore.now()) }
    }

    public func dismissCriticalIdlePrimaryDeviceModal() async throws {
        try await pool.write { try ServerAlerts.dismissCriticalModal($0, now: MessageStore.now()) }
    }
}
