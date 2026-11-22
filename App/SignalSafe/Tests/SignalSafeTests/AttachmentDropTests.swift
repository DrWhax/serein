// Dropped files and images become attachments. A file a drag's source delivers (a browser's or
// Photos' file promise) is read only if it is a regular file with one link, directly in the
// folder we gave it: never a link to one of our own files.

import AppKit
import Foundation
import Testing
@testable import SignalSafe
@testable import SignalUI

@MainActor @Suite(.serialized) struct AttachmentDropTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drops-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func aDeliveredImageIsRead() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cat.png")
        try Self.png.write(to: file)
        #expect(SignalSession.readDelivered(file, in: dir) == DroppedFile(data: Self.png, contentType: "image/png", fileName: "cat.png"))
    }

    /// A source cannot hand us a link to one of our own files (or anything else) to read.
    @Test func linksAndFilesElsewhereAreRefused() throws {
        let dir = try folder(), elsewhere = try folder()
        defer { for d in [dir, elsewhere] { try? FileManager.default.removeItem(at: d) } }
        let secret = elsewhere.appendingPathComponent("db.sqlite")
        try Data("secret".utf8).write(to: secret)
        // A symbolic link to it, in our folder.
        let link = dir.appendingPathComponent("cat.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(SignalSession.readDelivered(link, in: dir) == nil)
        // A hard link to it.
        let hard = dir.appendingPathComponent("dog.png")
        try FileManager.default.linkItem(at: secret, to: hard)
        #expect(SignalSession.readDelivered(hard, in: dir) == nil)
        // A file (one link) outside our folder, directly or through a linked folder inside ours.
        let other = elsewhere.appendingPathComponent("keys.json")
        try Data("secret".utf8).write(to: other)
        #expect(SignalSession.readDelivered(other, in: dir) == nil)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: elsewhere)
        #expect(SignalSession.readDelivered(sub.appendingPathComponent("keys.json"), in: dir) == nil)
        // A folder, not a file.
        let nested = dir.appendingPathComponent("nested.png", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        #expect(SignalSession.readDelivered(nested, in: dir) == nil)
    }

    @Test func tooLargeIsRefused() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(SignalSession.maxAttachmentBytes + 1))    // sparse
        try h.close()
        #expect(SignalSession.readDelivered(big, in: dir) == nil)
        #expect(SignalSession.readDropped(big) == nil)
    }

    /// The composer and the chat take files, PNG data (and promises) as attachments; text stays text.
    @Test func pasteboardsWithAttachments() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("drop-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("hello", forType: .string)
        let session = SignalSession()
        session.selectedConversationId = "chat"
        #expect(!session.pasteAttachments(pb))
        pb.clearContents()
        pb.setData(Self.png, forType: .png)
        #expect(session.pasteAttachments(pb))
        #expect(session.staged.map(\.data) == [Self.png])
        session.clearStaged()
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.png")
        try Self.png.write(to: file)
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        session.selectedConversationId = nil
        #expect(!session.pasteAttachments(pb) && session.staged.isEmpty)
        session.selectedConversationId = "chat"
        #expect(session.pasteAttachments(pb))
        #expect(session.staged.map(\.fileName) == ["photo.png"] && session.staged.first?.data == Self.png)
    }

    @Test func composerReadsImageOnlyPasteboardAndKeepsCaption() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let nativeImage = NSImage(size: NSSize(width: 3, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(nativeImage.tiffRepresentation)
        pb.setData(tiff, forType: .tiff)
        let session = SignalSession()
        session.selectedConversationId = "chat"
        let editor = PlaceholderTextView(frame: .zero)
        editor.isRichText = true
        editor.importsGraphics = false
        editor.string = "caption"
        editor.pasteAttachments = session.pasteAttachments
        #expect(editor.readablePasteboardTypes.contains(.tiff))
        #expect(editor.readSelection(from: pb))
        #expect(editor.string == "caption")
        #expect(session.staged.map(\.contentType) == ["image/tiff"])
        #expect(session.staged.map(\.data) == [tiff])
    }

    @Test func pastePrefersOneRepresentationPerImage() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(Self.png, forType: .png)
        first.setData(Data([1]), forType: .tiff)
        first.setString("image caption", forType: .string)
        second.setData(Data([2, 3]), forType: NSPasteboard.PasteboardType("public.jpeg"))
        pb.writeObjects([first, second])
        let session = SignalSession()
        session.selectedConversationId = "chat"
        #expect(session.pasteAttachments(pb))
        #expect(session.staged.map(\.contentType) == ["image/png", "image/jpeg"])
        #expect(session.staged.map(\.data) == [Self.png, Data([2, 3])])
    }

    @Test func pasteHandlesFileURLsAlongsideInlineImages() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("finder.png")
        try Self.png.write(to: file)
        let inline = NSPasteboardItem()
        inline.setString(dir.appendingPathComponent("unavailable.png").absoluteString, forType: .fileURL)
        inline.setData(Self.png, forType: .png)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.writeObjects([inline, file as NSURL])
        let session = SignalSession()
        session.selectedConversationId = "chat"
        #expect(session.pasteAttachments(pb))
        #expect(session.staged.map(\.fileName) == ["image.png", "finder.png"])
    }
}
