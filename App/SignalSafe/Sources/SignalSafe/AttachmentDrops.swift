// Files and images dropped on a chat or its composer become attachments (upstream's drop
// zone). Finder files are read where they are. Chat drops consume SwiftUI's item providers:
// SwiftUI already receives browser/Photos file promises into its own cache, so requesting
// them again from the drag pasteboard would compete with that delivery. The native composer
// receives promises into a fresh folder of ours.
//
// Either way the file was written by the drag's source, so it is read only if it is a regular
// file with one link, opened without following a link (in the composer's case, directly in our
// folder): a source cannot hand us a link to our database or keys to stage for sending. In the
// chat's case we see NSItemProvider's copy: it keeps a symbolic link a link, which is refused,
// but copies a hard link as a plain file. Making a hard link to one of our files needs access
// to our container in the first place.

import Foundation
#if os(macOS)
import AppKit
import System
#endif
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
        #if os(macOS)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxAttachmentBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return DroppedFile(data: data, contentType: mimeType(url), fileName: url.lastPathComponent)
    }

    nonisolated static func mimeType(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    #if os(macOS)
    /// A file a drag's source delivered into `folder`: read only if it is directly in `folder`
    /// (after resolving links), and then as `readSourceWritten` reads it.
    nonisolated static func readDelivered(_ url: URL, in folder: URL) -> DroppedFile? {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return readSourceWritten(parent.appendingPathComponent(url.lastPathComponent))
    }

    /// A file a drag's source wrote: read only if it is a regular file with one link, opened
    /// without following a link, at most `maxAttachmentBytes`.
    nonisolated static func readSourceWritten(_ url: URL) -> DroppedFile? {
        let path = url.path
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
                // This copy belongs to NSItemProvider and expires when the callback returns. It
                // keeps a symbolic link the source wrote a link, which is refused.
                continuation.resume(returning: error == nil ? url.flatMap { readSourceWritten($0) } : nil)
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
    #endif
}
