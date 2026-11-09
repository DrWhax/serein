// Downloading and saving attachments (upstream `kickOffAttachmentDownload`, `saveAttachment`,
// `saveAttachments`): an attachment that was not fetched automatically is queued on request; a
// downloaded one is saved where the user chooses (Downloads by default), with the quarantine
// properties a browser download gets, and a "Saved" toast with "Show in Finder". Dangerous file
// types are refused, as upstream does.

import AppKit
import Foundation
import SignalCore
import SignalUI

@MainActor extension SignalSession {
    /// `kickOffAttachmentDownload`: queues the message's attachments that are not here yet.
    func downloadAttachments(_ m: TimelineMessage) {
        guard let session = signalSession else { return }
        let missing = m.attachments.filter { !$0.attachment.isDownloaded && !($0.attachment.pending ?? false) }.map(\.location)
        guard !missing.isEmpty else { return }
        Task {
            do {
                try await session.downloads.requestDownload(missing)
            } catch {
                Self.trace("download request failed: \(error)")
                toast = .attachmentDownloadFailed
            }
        }
    }

    /// `cancelAttachmentDownload`: stops the message's downloads.
    func cancelDownloads(_ m: TimelineMessage) {
        guard let session = signalSession else { return }
        let id = m.id
        Task {
            do { try await session.downloads.cancelDownloads(messageId: id) } catch { Self.trace("cancel download failed: \(error)") }
        }
    }

    /// `isFileDangerous`
    static func isFileDangerous(_ name: String) -> Bool {
        let dangerous: Set<String> = ["ade", "adp", "apk", "bat", "cab", "chm", "cmd", "com", "cpl", "diagcab", "dll", "dmg", "exe", "hta", "inf",
                                      "ins", "isp", "jar", "js", "jse", "lib", "lnk", "mde", "mht", "msc", "msi", "msp", "mst", "nsh", "pif",
                                      "ps1", "psc1", "psm1", "psrc", "reg", "scr", "sct", "settingcontent-ms", "shb", "sys", "vb", "vbe",
                                      "vbs", "vxd", "wsc", "wsf", "wsh"]
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        guard let dot = trimmed.lastIndex(of: ".") else { return false }
        return dangerous.contains(trimmed[trimmed.index(after: dot)...].lowercased())
    }

    /// `getSuggestedFilename` (saving locally): the file's own name, else
    /// signal-YYYY-MM-DD-HH-mm-ss-SSS[_NNN].ext.
    static func suggestedFilename(_ a: SignalCore.MessageAttachment, sentAt: Int64, index: Int) -> String {
        if let name = a.fileName, !name.isEmpty { return (name as NSString).lastPathComponent }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "-yyyy-MM-dd-HH-mm-ss-SSS"
        let ext: String? = switch a.contentType {
        case "video/quicktime": "mov"
        case "audio/mpeg": "mp3"
        case "image/jpeg": "jpg"
        default: a.contentType.split(separator: "/").dropFirst().first.map(String.init)
        }
        let suffix = index > 1 ? "_" + String(repeating: "0", count: max(0, 3 - String(index).count)) + String(index) : ""
        return "serein" + f.string(from: Date(milliseconds: sentAt)) + suffix + (ext.map { "." + $0 } ?? "")
    }

    /// `saveAttachment` (one) / `saveAttachments` (all of the message's): a save panel for one
    /// file, a folder chooser for several.
    func saveAttachments(_ m: TimelineMessage, only index: Int? = nil) {
        let chosen = index.map { i in m.attachments.indices.contains(i) ? [m.attachments[i]] : [] } ?? m.attachments
        let files = chosen.map(\.attachment)
        guard !files.isEmpty else { return }
        let missing = files.filter { !$0.isDownloaded }.count
        if missing > 0 {
            downloadAttachments(m)
            toast = .attachmentDownloadStillInProgress(count: missing)
            return
        }
        let names = files.enumerated().map { i, a in Self.suggestedFilename(a, sentAt: m.sentAt, index: (index ?? i) + 1) }
        if names.contains(where: Self.isFileDangerous) {
            toast = .dangerousFileType
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        var targets: [URL] = []
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.directoryURL = downloads
            panel.nameFieldStringValue = names[0]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            targets = [url]
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = downloads
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            targets = names.map { Self.unusedURL(dir.appendingPathComponent($0)) }
        }
        guard let store = signalSession?.attachmentStore else { return }
        var saved = 0
        for (a, url) in zip(files, targets) {
            do {
                try store.export(a, to: url)
                saved += 1
            } catch {
                Self.trace("save failed: \(error)")
            }
        }
        if saved > 0, let first = targets.first {
            toast = .fileSaved(fullPath: first.path, countOfFiles: saved)
        } else {
            toast = .error
        }
    }

    /// `getUnusedFilename`: "name (1).ext", "name (2).ext", … when the name is taken.
    static func unusedURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        for n in 1... {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
