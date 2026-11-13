// Files and images dropped on a chat or its composer become attachments (upstream's drop
// zone). A Finder file is read where it is, as a file chosen in the open panel is. An image a
// browser or Photos hands over as a file promise (Chromium's image drags, Photos) is delivered
// by its source into a fresh folder of ours and read from there. Before, the chat accepted only
// file URLs, so a browser's image was refused.
//
// A promised file is written by the source app, so it is read only if it is a regular file
// with one link, directly in that folder, opened without following a link: a source cannot
// hand us a link to one of our own files (the database, keys) to read and stage for sending.

import AppKit
import Foundation
import System
import UniformTypeIdentifiers

/// A dropped or pasted file, read: its bytes, MIME type and name.
struct DroppedFile: Sendable, Equatable {
    var data: Data
    var contentType: String
    var fileName: String
}

@MainActor extension SignalSession {
    // MARK: reading

    /// A file the user chose (dropped from Finder, pasted, picked): read where it is (a
    /// security-scoped one opened for the read), at most `maxAttachmentBytes`.
    nonisolated static func readDropped(_ url: URL) -> DroppedFile? {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxAttachmentBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return DroppedFile(data: data, contentType: mimeType(url), fileName: url.lastPathComponent)
    }

    nonisolated static func mimeType(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A file a drag's source delivered into `folder`: read only if it is a regular file with
    /// one link, directly in `folder` (after resolving links), opened without following a link.
    nonisolated static func readDelivered(_ url: URL, in folder: URL) -> DroppedFile? {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        let path = parent.appendingPathComponent(url.lastPathComponent).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxAttachmentBytes,
              let fd = try? FileDescriptor.open(FilePath(path), .readOnly, options: [.noFollow, .closeOnExec])
        else { return nil }
        let handle = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxAttachmentBytes + 1), data.count <= maxAttachmentBytes else { return nil }
        return DroppedFile(data: data, contentType: mimeType(url), fileName: url.lastPathComponent)
    }

    // MARK: pasteboards

    /// Whether a pasteboard holds something to attach: files, file promises, or PNG/JPEG data.
    nonisolated static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.availableType(from: [.png, NSPasteboard.PasteboardType("public.jpeg")]) != nil
    }

    /// Items dropped on the chat: read from the drag pasteboard, as a drop on the composer is
    /// (SwiftUI's item providers cannot take a file promise into a folder of ours).
    func stageDropped() -> Bool {
        let drag = NSPasteboard(name: .drag)
        guard selectedConversationId != nil, editingMessageId == nil, Self.hasAttachments(drag) else { return false }
        return pasteAttachments(drag)
    }

    /// File promises on a pasteboard (a drag from a browser or Photos): each delivered into a
    /// fresh folder of ours, read (`readDelivered`), staged, and removed.
    func receivePromisedFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty
        else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else { return false }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { [weak self] url, error in
                let file = error == nil ? Self.readDelivered(url, in: folder) : nil
                try? FileManager.default.removeItem(at: url)
                Task { @MainActor in
                    guard let self else { return }
                    guard let file else { return Self.trace("drop: promised file refused or not delivered") }
                    self.stage(file.data, contentType: file.contentType, fileName: file.fileName)
                }
            }
        }
        return true
    }
}
