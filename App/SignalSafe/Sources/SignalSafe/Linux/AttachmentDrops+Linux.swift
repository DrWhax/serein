#if os(Linux)
import Foundation
import SignalSafeSystem
import SignalUI
import SwiftUI

@MainActor extension SignalSession {
    func pasteAttachments(_ providers: ComposerPasteboard) -> Bool { stageDropped(providers) }

    func stageDropped(_ providers: [NSItemProvider]) -> Bool {
        guard selectedConversationId != nil, editingMessageId == nil else { return false }
        let supported = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
            provider.registeredTypeIdentifiers.compactMap { UTType($0) }.contains {
                $0.conforms(to: .data) && !$0.conforms(to: .text)
            }
        }
        guard !supported.isEmpty else { return false }
        Task {
            for provider in supported {
                for file in await Self.droppedFiles(provider) {
                    stage(file.data, contentType: file.contentType, fileName: file.fileName)
                }
            }
        }
        return true
    }

    private static func droppedFiles(_ provider: NSItemProvider) async -> [DroppedFile] {
        func bytes(_ type: UTType) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let data = await bytes(.url), let entries = String(data: data, encoding: .utf8) {
            let files = entries.split(whereSeparator: \.isNewline).compactMap { entry -> DroppedFile? in
                guard !entry.hasPrefix("#"), let url = URL(string: String(entry)),
                      let data = DesktopDocuments.readDrop(url, limit: maxAttachmentBytes) else { return nil }
                return DroppedFile(data: data, contentType: mimeType(url), fileName: url.lastPathComponent)
            }
            if !files.isEmpty { return files }
        }
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let ordered = ComposerAttachmentPasteboard.imageTypes.filter(types.contains) + types
        for type in ordered where type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text) {
            guard let data = await bytes(type), !data.isEmpty, data.count <= maxAttachmentBytes else { continue }
            let ext = type == .jpeg ? "jpg" : type.preferredFilenameExtension
            let name = type == .tiff ? "" : (ext.map { "attachment.\($0)" } ?? "attachment")
            return [DroppedFile(data: data, contentType: type.preferredMIMEType ?? "application/octet-stream", fileName: name)]
        }
        return []
    }
}
#endif
