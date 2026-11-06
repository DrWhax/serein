import CoreGraphics
import Foundation
import Testing
@testable import SignalUI

@Suite struct MediaEditorModelTests {
    /// Upstream's `getNewImageStateFromCrop` table.
    static func upstreamCrop(_ s: MediaEditorImageState, _ r: CGRect) -> (CGFloat, CGFloat) {
        switch s.angle {
        case 90: (s.cropX + r.minY, s.cropY + (s.width - r.maxX))
        case 180: (s.cropX + (s.width - r.maxX), s.cropY + (s.height - r.maxY))
        case 270: (s.cropX + (s.height - r.maxY), s.cropY + r.minX)
        default: (s.cropX + r.minX, s.cropY + r.minY)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func cropMatchesUpstreamWithoutFlips(turns: Int) {
        var s = MediaEditorSnapshot(objects: [], image: MediaEditorImageState(width: 400, height: 300))
        s.image.cropX = 7
        s.image.cropY = 11
        for _ in 0 ..< turns { MediaEditorGeometry.rotate(&s) }
        let r = CGRect(x: 30, y: 20, width: 100, height: 50)
        let expected = Self.upstreamCrop(s.image, r)
        var c = s
        MediaEditorGeometry.crop(&c, to: r)
        #expect(abs(c.image.cropX - expected.0) < 1e-9 && abs(c.image.cropY - expected.1) < 1e-9, "angle \(s.image.angle): \(c.image) vs \(expected)")
        #expect(c.image.width == 100 && c.image.height == 50)
    }

    /// With a flip, the kept region is the one selected on screen: a canvas point maps to the
    /// same source pixel before and after the crop.
    @Test(arguments: [0, 1, 2, 3])
    func cropAfterFlipKeepsTheSelection(turns: Int) {
        var s = MediaEditorSnapshot(objects: [], image: MediaEditorImageState(width: 400, height: 300))
        for _ in 0 ..< turns { MediaEditorGeometry.rotate(&s) }
        MediaEditorGeometry.flip(&s)
        let r = CGRect(x: 30, y: 20, width: 100, height: 50)
        func source(_ img: MediaEditorImageState, _ p: CGPoint) -> CGPoint {
            let l = p.applying(img.imageTransform.inverted())
            return CGPoint(x: l.x + img.cropX, y: l.y + img.cropY)
        }
        var c = s
        MediaEditorGeometry.crop(&c, to: r)
        for p in [CGPoint(x: 31, y: 21), CGPoint(x: 129, y: 69), CGPoint(x: 80, y: 40)] {
            let before = source(s.image, p), after = source(c.image, CGPoint(x: p.x - r.minX, y: p.y - r.minY))
            #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9, "turns \(turns) \(p): \(before) vs \(after)")
        }
    }

    @Test func rotateAndReset() {
        let obj = MediaEditorObject(id: 1, kind: .sticker(RGBAImage(width: 1, height: 1, pixels: Data(count: 4))), center: CGPoint(x: 50, y: 60), angle: 10)
        var s = MediaEditorSnapshot(objects: [obj], image: MediaEditorImageState(width: 400, height: 300))
        MediaEditorGeometry.rotate(&s)
        #expect(s.image.angle == 270 && s.image.width == 300 && s.image.height == 400)
        #expect(s.objects[0].center == CGPoint(x: 60, y: 350) && s.objects[0].angle == 280)
        for _ in 0 ..< 3 { MediaEditorGeometry.rotate(&s) }
        #expect(s.image == MediaEditorImageState(width: 400, height: 300) && s.objects[0].center == obj.center && s.objects[0].angle == 10)
        // Rotate, crop, then reset: the object is back where it was over the source.
        MediaEditorGeometry.rotate(&s)
        MediaEditorGeometry.crop(&s, to: CGRect(x: 20, y: 30, width: 200, height: 250))
        MediaEditorGeometry.reset(&s, sourceWidth: 400, sourceHeight: 300)
        #expect(s.image == MediaEditorImageState(width: 400, height: 300))
        #expect(abs(s.objects[0].center.x - 50) < 1e-9 && abs(s.objects[0].center.y - 60) < 1e-9)
        #expect((s.objects[0].angle - 10).truncatingRemainder(dividingBy: 360) == 0)
    }

    @Test func history() {
        var h = MediaEditorHistory()
        let a = MediaEditorSnapshot(objects: [], image: MediaEditorImageState(width: 10, height: 10))
        var b = a; b.image.angle = 270
        var c = a; c.image.flipX = true
        h.take(a)
        #expect(!h.canUndo && !h.canRedo)
        h.take(b); h.take(b)
        #expect(h.snapshots.count == 2 && h.canUndo)
        #expect(h.undo() == a && !h.canUndo && h.canRedo && h.undo() == nil)
        h.take(c)
        #expect(h.snapshots == [a, c] && !h.canRedo)
        for i in 0 ..< 1100 { var s = a; s.image.cropX = CGFloat(i); h.take(s) }
        #expect(h.snapshots.count == MediaEditorHistory.limit)
    }

    @Test func colours() {
        func hex(_ c: RGBA) -> [Int] { [c.r, c.g, c.b].map { Int(($0 * 255).rounded()) } }
        #expect(hex(MediaEditorColor.color(0)) == [0, 0, 0])
        #expect(hex(MediaEditorColor.color(100)) == [255, 255, 255])
        #expect(hex(MediaEditorColor.color(7.0001)) == [255, 0, 0])
        #expect(hex(MediaEditorColor.color(51)) == [0, 255, 208])      // hsl(169°, 100%, 50%)
        #expect(hex(MediaEditorColor.color(3.5)) == [96, 32, 32])      // hsl(0, 50%, 25%)
        let t = MediaEditorColor.text(.highlight, hue: 96)
        #expect(t.fill == RGBA(0, 0, 0) && t.background != nil)
    }

    @Test func pencil() {
        let pts = (0 ..< 20).map { CGPoint(x: CGFloat($0) * 0.1, y: 0) }
        let d = MediaEditorPencil.decimate(pts, distance: 0.4)
        #expect(d.first == pts.first && d.last == pts.last && d.count == 6)
        let path = MediaEditorPencil.path([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 10)], width: 1000)
        // M (0 - 1, 0 - 0) … L (20 + 1, 10 + 1)
        #expect(path.boundingBoxOfPath.minX == -1 && path.currentPoint == CGPoint(x: 21, y: 11))
    }
}
