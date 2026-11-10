// Crash reports (app/crashReports.main.ts): on launch, crashes since the last look are offered
// in CrashReportDialog — written to the debug log (summarised: exception, crashing thread's
// frames in our own images) or dismissed. Upstream collects Crashpad minidumps and reads them
// with libsignal's Minidump (Node-only); a Swift app can't host Crashpad without C++, so this
// reads macOS's own crash reports for the app (DiagnosticReports/<name>-*.ips: a JSON header
// line, then the JSON report), the same information.

import Foundation

public struct CrashReportSummary: Sendable, Hashable {
    public var file: URL
    public var date: Date?
    public var appVersion: String?
    public var osVersion: String?
    public var exceptionType: String?
    public var signal: String?
    /// The crashing thread's frames: "image + offset (symbol)".
    public var frames: [String]

    /// The debug-log text (`crashReports: dump=… mtime=…` + the JSON summary upstream).
    public var logText: String {
        var lines = ["crashReports: dump=\(file.lastPathComponent) date=\(date.map { ISO8601DateFormatter().string(from: $0) } ?? "?")"]
        lines.append("  app \(appVersion ?? "?") on \(osVersion ?? "?"): \(exceptionType ?? "?") \(signal ?? "")")
        lines += frames.prefix(32).map { "    \($0)" }
        return lines.joined(separator: "\n")
    }
}

public struct CrashReports {
    let directory: URL
    let processName: String
    let defaults: UserDefaults
    static let seenKey = "crashReports.lastSeen"

    /// In the user's real home (the sandbox's home is the container); the app's entitlements
    /// let it read DiagnosticReports there, nothing else.
    public static var reportsDirectory: URL {
        URL(fileURLWithPath: AppSandbox.realHome).appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    public init(directory: URL = CrashReports.reportsDirectory,
                processName: String = ProcessInfo.processInfo.processName, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.processName = processName
        self.defaults = defaults
    }

    var lastSeen: Date { Date(timeIntervalSince1970: defaults.double(forKey: Self.seenKey)) }

    /// `getPendingDumps`: our reports newer than the last ones handled.
    public func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            url.pathExtension == "ips" && url.lastPathComponent.hasPrefix(processName + "-")
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > lastSeen
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `crash-reports:get-count`
    public var count: Int { pending().count }

    /// `crash-reports:write-to-log`: the summaries, then they count as handled.
    public func writeToLog() -> [CrashReportSummary] {
        let summaries = pending().compactMap(Self.summary)
        erase()
        return summaries
    }

    /// `crash-reports:erase`: macOS keeps its reports; these stop counting as pending.
    public func erase() { defaults.set(Date().timeIntervalSince1970, forKey: Self.seenKey) }

    /// Reads one report: the header line and the report body (both JSON).
    public static func summary(_ url: URL) -> CrashReportSummary? {
        guard let data = try? Data(contentsOf: url), let newline = data.firstIndex(of: 0x0A) else { return nil }
        let header = (try? JSONSerialization.jsonObject(with: data[..<newline])) as? [String: Any] ?? [:]
        guard let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any] else { return nil }
        let exception = body["exception"] as? [String: Any]
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? Int).flatMap { $0 < threads.count ? threads[$0] : nil } ?? threads.first { $0["triggered"] as? Bool == true }
        let frames = (faulting?["frames"] as? [[String: Any]] ?? []).map { f -> String in
            let image = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0] : nil } ?? "?"
            let offset = (f["imageOffset"] as? Int).map { "+ \($0)" } ?? ""
            let symbol = (f["symbol"] as? String).map { " (\($0))" } ?? ""
            return "\(image) \(offset)\(symbol)"
        }
        let os = (body["osVersion"] as? [String: Any]).map { "\($0["train"] as? String ?? "") \($0["build"] as? String ?? "")" }
        let date = (header["timestamp"] as? String).flatMap { s -> Date? in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
            return f.date(from: s)
        }
        return CrashReportSummary(file: url, date: date, appVersion: header["app_version"] as? String, osVersion: os,
                                  exceptionType: exception?["type"] as? String, signal: exception?["signal"] as? String, frames: frames)
    }
}
