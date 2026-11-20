// Files and images dropped on a chat or its composer become attachments (upstream's drop
// zone). Finder files are read where they are. Chat drops consume SwiftUI's item providers:
// SwiftUI already receives browser/Photos file promises into its own cache, so requesting
// them again from the drag pasteboard would compete with that delivery.
//
// The native composer receives promises into a fresh folder of ours. A source-supplied file
// is read only if it is a regular file with one link directly in that folder, opened without
// following a link: a source cannot hand us a link to our database or keys to stage for sending.

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

    /// SwiftUI has already called in file promises into its own cache. Consume its providers
    /// rather than requesting the same promises again with a different destination.
    func stageDropped(_ providers: [NSItemProvider]) -> Bool {
        guard selectedConversationId != nil, editingMessageId == nil, !providers.isEmpty else { return false }
        Task {
            for provider in providers {
                guard let file = await Self.readDroppedProvider(provider) else { continue }
                stage(file.data, contentType: file.contentType, fileName: file.fileName)
            }
        }
        return true
    }

    static func readDroppedProvider(_ provider: NSItemProvider) async -> DroppedFile? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    continuation.resume(returning: error == nil ? url.flatMap { readDropped($0) } : nil)
                }
            }
        }
        // Prefer the image/movie over a browser's accompanying page URL or text.
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard let type = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) })
            ?? types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) })
        else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                // This copy belongs to NSItemProvider and expires when the callback returns.
                continuation.resume(returning: error == nil ? url.flatMap { readDropped($0) } : nil)
            }
        }
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
        let reader = promisedFileReader(in: folder)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue, reader: reader)
        }
        return true
    }

    /// AppKit invokes this on its delivery queue. Sendable prevents inherited main-actor
    /// isolation, which would trap at callback entry before the Task can hop back.
    func promisedFileReader(in folder: URL) -> @Sendable (URL, (any Error)?) -> Void {
        { @Sendable [weak self] url, error in
            let file = error == nil ? Self.readDelivered(url, in: folder) : nil
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in
                guard let self else { return }
                guard let file else { return Self.trace("drop: promised file refused or not delivered") }
                self.stage(file.data, contentType: file.contentType, fileName: file.fileName)
            }
        }
    }
}
