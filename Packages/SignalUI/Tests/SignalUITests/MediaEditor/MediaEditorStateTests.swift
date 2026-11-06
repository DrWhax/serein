import CodecCore
import Foundation
import ImageJPEG
import Testing
@testable import SignalUI

@MainActor
@Suite struct MediaEditorStateTests {
    /// 200 × 100: left half red, right half blue.
    static func image() -> RGBAImage {
        var px = [UInt8](repeating: 255, count: 200 * 100 * 4)
        for y in 0 ..< 100 { for x in 0 ..< 200 { let i = (y * 200 + x) * 4; px[i] = x < 100 ? 255 : 0; px[i + 1] = 0; px[i + 2] = x < 100 ? 0 : 255 } }
        return RGBAImage(width: 200, height: 100, pixels: Data(px))
    }

    func drag(_ s: MediaEditorState, _ points: [CGPoint]) {
        s.begin(points[0])
        for p in points.dropFirst() { s.changed(p) }
        s.ended(points.last!, wasTap: points.count == 1)
    }

    @Test func drawSelectMoveDelete() {
        let s = MediaEditorState(image: Self.image())
        s.zoom = 2
        s.setMode(.draw)
        s.slider = 50
        drag(s, (0 ... 20).map { CGPoint(x: 20 + CGFloat($0) * 4, y: 40) })
        guard case .path(_, let color, let width, .pen) = s.doc.objects.last?.kind else { Issue.record("no path"); return }
        #expect(color == MediaEditorColor.color(50) && width == 2)   // 4px regular at zoom 2
        #expect(s.canUndo)
        s.setMode(nil)
        // A sticker: centred, a quarter of the shorter side tall, selected.
        s.addSticker(RGBAImage(width: 10, height: 20, pixels: Data(count: 800)))
        let sticker = s.doc.objects.last!
        #expect(s.selected == sticker.id && sticker.center == CGPoint(x: 100, y: 50) && abs(sticker.scale * 20 - 25) < 1e-9)
        // Drag it by (10, 5) canvas pixels (20, 10 points at zoom 2).
        drag(s, [CGPoint(x: 200, y: 100), CGPoint(x: 210, y: 105), CGPoint(x: 220, y: 110)])
        #expect(s.doc.objects.last!.center == CGPoint(x: 110, y: 55))
        // Tap empty space: deselect; tap it again: selected; its delete control removes it.
        drag(s, [CGPoint(x: 10, y: 10)])
        #expect(s.selected == nil)
        drag(s, [CGPoint(x: 220, y: 110)])
        #expect(s.selected == sticker.id)
        let k = MediaEditorControls(s.selectedObject!, zoom: 2)
        drag(s, [k.delete])
        #expect(s.doc.objects.count == 1 && s.selected == nil)
        s.undo()
        #expect(s.doc.objects.count == 2)
        s.redo()
        #expect(s.doc.objects.count == 1)
    }

    @Test func textMode() {
        let s = MediaEditorState(image: Self.image())
        s.setMode(.text)
        #expect(s.editing != nil && s.doc.objects.count == 1)
        guard case .text(_, _, _, let size) = s.doc.objects[0].kind else { Issue.record("no text"); return }
        #expect(size == 10)   // min(200, 100) / 10
        s.setMode(nil)
        #expect(s.doc.objects.isEmpty)   // blank text goes
        s.setMode(.text)
        s.setText("Hi")
        s.textStyle = .outline
        s.setMode(nil)
        guard case .text("Hi", .outline, _, _) = s.doc.objects.last?.kind else { Issue.record("text not kept"); return }
        #expect(s.editing == nil && s.canUndo)
    }

    @Test func cropAndExport() throws {
        let s = MediaEditorState(image: Self.image())
        s.zoom = 1
        s.setMode(.crop)
        s.rotate()
        #expect(s.doc.image.width == 100 && s.doc.image.height == 200)
        s.setPreset(.square)
        s.applyCrop()
        #expect(s.doc.image.width == s.doc.image.height && s.mode == nil)
        let doc = s.exportDocument
        let r = try #require(MediaEditorExport.export(doc, background: s.background, caption: "c", isViewOnce: false, isHighQuality: true))
        #expect(r.contentType == "image/jpeg" && r.caption == "c" && r.isHighQuality)
        let decoded = try JPEGDecoder.decode([UInt8](r.data))
        #expect(decoded.width == Int(doc.image.width.rounded()) && decoded.height == decoded.width)
        #expect(r.blurHash.count == 28)   // 4 × 3 components
        // Turned a quarter counter-clockwise: the red (left) half is now at the bottom.
        let px = decoded.rgba, w = decoded.width
        let bottom = (w * (w - 5) + w / 2) * 4, top = (w * 5 + w / 2) * 4
        #expect(px[bottom] > 200 && px[bottom + 2] < 60 && px[top + 2] > 200 && px[top] < 60, "\(Array(px[bottom ..< bottom + 3])) \(Array(px[top ..< top + 3]))")
    }
}
