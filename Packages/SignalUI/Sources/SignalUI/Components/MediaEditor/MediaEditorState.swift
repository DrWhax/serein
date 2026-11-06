// The media editor's interaction state (what MediaEditor.dom.tsx keeps in React state and
// in Fabric's canvas): the edit mode, the selected object, the crop session, the tools, and
// the pointer gestures Fabric handles (select and move; the resize, rotate, delete and
// "More styles" controls; pencil drawing; the crop rectangle's corners and move), with a
// history snapshot after every change (`object:added` / `modified` / `removed`, crop,
// rotate, flip, reset).

import Foundation
import SwiftUI

/// `EditMode`
public enum MediaEditorMode: Sendable, Equatable { case crop, draw, text }

@MainActor
@Observable
final class MediaEditorState {
    let background: MediaEditorBitmap
    let sourceSize: CGSize
    var doc: MediaEditorSnapshot
    var history = MediaEditorHistory()
    var mode: MediaEditorMode?
    var selected: Int?
    /// A text object being typed into.
    var editing: Int?
    var crop: CGRect?
    /// The crop rectangle the session started with (it can only shrink).
    var cropStart: CGSize = .zero
    var canCrop = false
    var cropPreset = MediaEditorCropPreset.freeform
    var cropLocked = false
    var drawTool = MediaEditorDrawTool.pen
    var drawWidth = MediaEditorDrawWidth.regular
    var slider: Double = 0 { didSet { restyleSelectedText() } }
    var textStyle = MediaEditorTextStyle.regular { didSet { restyleSelectedText() } }
    /// Points of the stroke being drawn (canvas pixels).
    var drawing: [CGPoint] = []
    var nextID = 1
    var zoom: CGFloat = 1

    init(image: RGBAImage) {
        background = MediaEditorBitmap(image)
        sourceSize = CGSize(width: image.width, height: image.height)
        doc = MediaEditorSnapshot(objects: [], image: MediaEditorImageState(width: CGFloat(image.width), height: CGFloat(image.height)))
        history.take(doc)
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func commit() { history.take(doc) }

    func undo() {
        if mode == .crop { setMode(nil) }
        if let s = history.undo() { doc = s; selected = nil; editing = nil }
    }

    func redo() {
        if mode == .crop { setMode(nil) }
        if let s = history.redo() { doc = s; selected = nil; editing = nil }
    }

    var selectedObject: MediaEditorObject? { selected.flatMap { id in doc.objects.first { $0.id == id } } }

    func index(_ id: Int) -> Int? { doc.objects.firstIndex { $0.id == id } }

    // MARK: modes

    func setMode(_ m: MediaEditorMode?) {
        let old = mode
        if old == .text, m != .text { finishText() }
        if old == .crop, m != .crop { crop = nil; canCrop = false }
        mode = m
        switch m {
        case .crop:
            selected = nil
            cropPreset = .freeform
            startCrop()
        case .draw:
            selected = nil
        case .text:
            if let o = selectedObject, o.isText { editing = o.id } else { addText() }
        case nil:
            break
        }
    }

    /// Leaving text mode: stop typing, and blank text goes.
    func finishText() {
        if let id = editing ?? selected, let i = index(id), case .text(let s, _, _, _) = doc.objects[i].kind, s.isEmpty {
            doc.objects.remove(at: i)
            selected = nil
        }
        if editing != nil { commit() }
        editing = nil
    }

    func addText() {
        let fontSize = min(doc.image.width, doc.image.height) / 10
        let o = MediaEditorObject(id: take(), kind: .text("", style: textStyle, hue: slider, fontSize: fontSize),
                                  center: CGPoint(x: doc.image.width / 2, y: doc.image.height / 2))
        doc.objects.append(o)
        selected = o.id
        editing = o.id
    }

    func take() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    func setText(_ s: String) {
        guard let id = editing, let i = index(id), case .text(_, let style, let hue, let size) = doc.objects[i].kind else { return }
        doc.objects[i].kind = .text(s, style: style, hue: hue, fontSize: size)
    }

    var editingText: String {
        guard let id = editing, let o = doc.objects.first(where: { $0.id == id }), case .text(let s, _, _, _) = o.kind else { return "" }
        return s
    }

    func restyleSelectedText() {
        guard let id = selected, let i = index(id), case .text(let s, _, _, let size) = doc.objects[i].kind else { return }
        doc.objects[i].kind = .text(s, style: textStyle, hue: slider, fontSize: size)
        if editing == nil { commit() }
    }

    // MARK: stickers

    /// `handlePickSticker`: a quarter of the shorter side tall, centred, selected.
    func addSticker(_ img: RGBAImage) {
        let size = min(doc.image.width, doc.image.height) / 4
        let o = MediaEditorObject(id: take(), kind: .sticker(img), center: CGPoint(x: doc.image.width / 2, y: doc.image.height / 2),
                                  scale: size / CGFloat(max(1, img.height)))
        add(o)
    }

    /// `handlePickTimeSticker`: the digital clock at its own size; the analog one a quarter
    /// of the shorter side.
    func addTimeSticker(analog: Bool, now: Date = Date()) {
        let center = CGPoint(x: doc.image.width / 2, y: doc.image.height / 2)
        if analog {
            let size = min(doc.image.width, doc.image.height) / 4
            add(MediaEditorObject(id: take(), kind: .analogTime(AnalogTime(date: now), style: .arabic), center: center, scale: size / 600))
        } else {
            add(MediaEditorObject(id: take(), kind: .digitalTime(now, style: .white), center: center))
        }
    }

    func add(_ o: MediaEditorObject) {
        doc.objects.append(o)
        selected = o.id
        mode = nil
        commit()
    }

    func deleteSelected() {
        guard let id = selected, let i = index(id) else { return }
        doc.objects.remove(at: i)
        selected = nil
        editing = nil
        mode = nil
        commit()
    }

    /// The "More styles" control: the clock's next style.
    func cycleStyle(_ id: Int) {
        guard let i = index(id) else { return }
        switch doc.objects[i].kind {
        case .digitalTime(let d, let s): doc.objects[i].kind = .digitalTime(d, style: s.next)
        case .analogTime(let t, let s): doc.objects[i].kind = .analogTime(t, style: s.next)
        default: return
        }
        commit()
    }

    /// Arrow-key nudges (`moveObjectShortcut`): 1px (20 with shift), or degrees with option.
    func nudge(dx: CGFloat, dy: CGFloat, dAngle: Double, shift: Bool, option: Bool) {
        guard editing == nil, let id = selected, let i = index(id) else { return }
        let k: CGFloat = shift ? 20 : 1
        if option { doc.objects[i].angle += Double(k) * dAngle } else { doc.objects[i].center.x += k * dx; doc.objects[i].center.y += k * dy }
        commit()
    }

    // MARK: crop

    func startCrop() {
        crop = MediaEditorGeometry.initialCropRect(doc.image, zoom: zoom, preset: .freeform)
        cropStart = crop!.size
        canCrop = false
    }

    func setPreset(_ p: MediaEditorCropPreset) {
        cropPreset = p
        let r = MediaEditorGeometry.initialCropRect(doc.image, zoom: zoom, preset: p)
        crop = r
        canCrop = true
    }

    func rotate() {
        MediaEditorGeometry.rotate(&doc)
        commit()
        if mode == .crop { startCrop() }
    }

    func flip() {
        MediaEditorGeometry.flip(&doc)
        commit()
    }

    func reset() {
        MediaEditorGeometry.reset(&doc, sourceWidth: sourceSize.width, sourceHeight: sourceSize.height)
        cropPreset = .freeform
        commit()
        if mode == .crop { startCrop() }
    }

    /// Done in crop mode: apply the pending crop (if it changed), leave the mode.
    func applyCrop() {
        if canCrop, let r = crop {
            MediaEditorGeometry.crop(&doc, to: r)
            commit()
        }
        cropPreset = .freeform
        setMode(nil)
    }

    // MARK: pointer

    enum Drag {
        case none, draw
        case move(id: Int, offset: CGPoint, moved: Bool)
        case resize(id: Int, anchor: CGPoint, startScale: CGFloat, startDistance: CGFloat)
        case rotate(id: Int, startAngle: Double, startPointer: Double)
        case tapControl(id: Int, delete: Bool)
        case cropMove(offset: CGPoint)
        case cropCorner(anchor: CGPoint, aspect: CGFloat?)
        case deselect
    }

    @ObservationIgnored var drag = Drag.none

    static let controlRadius: CGFloat = 12, cropHit: CGFloat = 24

    /// `p` in view points (the canvas at `zoom`).
    func begin(_ p: CGPoint) {
        let q = CGPoint(x: p.x / zoom, y: p.y / zoom)
        if mode == .crop, let r = crop {
            let s = CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
            let corners = [(CGPoint(x: s.minX, y: s.minY), CGPoint(x: r.maxX, y: r.maxY)), (CGPoint(x: s.maxX, y: s.minY), CGPoint(x: r.minX, y: r.maxY)),
                           (CGPoint(x: s.minX, y: s.maxY), CGPoint(x: r.maxX, y: r.minY)), (CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: r.minX, y: r.minY))]
            if let hit = corners.first(where: { abs($0.0.x - p.x) <= Self.cropHit && abs($0.0.y - p.y) <= Self.cropHit }) {
                drag = .cropCorner(anchor: hit.1, aspect: cropLocked ? r.width / r.height : nil)
            } else if r.contains(q) {
                drag = .cropMove(offset: CGPoint(x: q.x - r.minX, y: q.y - r.minY))
            } else {
                drag = .none
            }
            return
        }
        if mode == .draw {
            drawing = [q]
            drag = .draw
            return
        }
        if let o = selectedObject {
            let k = MediaEditorControls(o, zoom: zoom)
            func near(_ c: CGPoint, _ r: CGFloat = Self.controlRadius) -> Bool { hypot(c.x - p.x, c.y - p.y) <= r }
            if near(k.delete) { drag = .tapControl(id: o.id, delete: true); return }
            if let m = k.moreStyles, abs(m.x - p.x) <= 50, p.y >= m.y, p.y <= m.y + 33 { drag = .tapControl(id: o.id, delete: false); return }
            if near(k.resize) {
                let anchor = o.corners[0]
                drag = .resize(id: o.id, anchor: anchor, startScale: o.scale, startDistance: max(1, hypot(q.x - anchor.x, q.y - anchor.y)))
                return
            }
            if near(k.rotate) {
                drag = .rotate(id: o.id, startAngle: o.angle, startPointer: atan2(q.y - o.center.y, q.x - o.center.x) * 180 / .pi)
                return
            }
        }
        if let o = doc.objects.last(where: { $0.isSelectable && $0.contains(q) }) {
            if o.id != selected, editing != nil { finishText() }
            drag = .move(id: o.id, offset: CGPoint(x: q.x - o.center.x, y: q.y - o.center.y), moved: false)
            return
        }
        drag = .deselect
    }

    func changed(_ p: CGPoint) {
        let q = CGPoint(x: p.x / zoom, y: p.y / zoom)
        switch drag {
        case .draw:
            if drawing.last != q { drawing.append(q) }
        case .move(let id, let offset, _):
            guard let i = index(id) else { return }
            doc.objects[i].center = CGPoint(x: q.x - offset.x, y: q.y - offset.y)
            drag = .move(id: id, offset: offset, moved: true)
            if selected != id { selected = id }
        case .resize(let id, let anchor, let startScale, let startDistance):
            guard let i = index(id) else { return }
            let s = max(0.01, startScale * hypot(q.x - anchor.x, q.y - anchor.y) / startDistance)
            var o = doc.objects[i]
            o.scale = s
            // The opposite (top-left) corner stays put.
            let half = CGPoint(x: o.size.width * s / 2, y: o.size.height * s / 2)
            let a = o.angle * .pi / 180
            o.center = CGPoint(x: anchor.x + half.x * cos(a) - half.y * sin(a), y: anchor.y + half.x * sin(a) + half.y * cos(a))
            doc.objects[i] = o
        case .rotate(let id, let startAngle, let startPointer):
            guard let i = index(id) else { return }
            let o = doc.objects[i]
            let now = atan2(q.y - o.center.y, q.x - o.center.x) * 180 / .pi
            doc.objects[i].angle = startAngle + (now - startPointer)
        case .cropMove(let offset):
            guard let r = crop else { return }
            let moved = CGRect(x: q.x - offset.x, y: q.y - offset.y, width: r.width, height: r.height)
            crop = MediaEditorGeometry.containCrop(moved, start: cropStart, image: doc.image, zoom: zoom)
        case .cropCorner(let anchor, let aspect):
            var w = max(1, abs(q.x - anchor.x)), h = max(1, abs(q.y - anchor.y))
            if let aspect {
                // Locked: the starting aspect ratio, shrunk as a whole to fit the start size.
                if w / h > aspect { w = h * aspect } else { h = w / aspect }
                let k = min(1, cropStart.width / w, cropStart.height / h)
                w *= k
                h *= k
            } else {
                w = min(w, cropStart.width)
                h = min(h, cropStart.height)
            }
            let x = q.x < anchor.x ? anchor.x - w : anchor.x, y = q.y < anchor.y ? anchor.y - h : anchor.y
            crop = MediaEditorGeometry.containCrop(CGRect(x: x, y: y, width: w, height: h), start: cropStart, image: doc.image, zoom: zoom)
        case .none, .tapControl, .deselect:
            break
        }
    }

    func ended(_ p: CGPoint, wasTap: Bool) {
        let d = drag
        drag = .none
        switch d {
        case .draw:
            addPath()
        case .move(let id, _, let moved):
            let wasSelected = selected == id
            selected = id
            if moved { commit() }
            if let o = selectedObject, o.isText {
                if mode != .text { mode = .text }
                if wasSelected && !moved { editing = id }
            } else if mode == .text {
                mode = nil
            }
        case .resize, .rotate:
            commit()
        case .tapControl(let id, let delete):
            guard wasTap else { return }
            if delete { selected = id; deleteSelected() } else { cycleStyle(id) }
        case .cropMove, .cropCorner:
            if let r = crop { canCrop = r.height < cropStart.height - 1e-9 || r.width < cropStart.width - 1e-9 }
        case .deselect:
            if editing != nil { finishText() }
            selected = nil
            if mode == .text { mode = nil }
        case .none:
            break
        }
    }

    /// The finished stroke as a path object (decimated; the brush's colour and width).
    func addPath() {
        let pts = MediaEditorPencil.decimate(drawing, distance: 0.4 / zoom)
        drawing = []
        guard !pts.isEmpty else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let c = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        let rel = pts.map { CGPoint(x: $0.x - c.x, y: $0.y - c.y) }
        doc.objects.append(MediaEditorObject(id: take(), kind: .path(points: rel, color: brushColor, width: brushWidth, tool: drawTool), center: c))
        commit()
    }

    /// The brush (`MediaEditorFabricPencilBrush`): the hue as HSL, or as RGBA at half alpha and
    /// twice as wide for the highlighter; widths are screen pixels at the current zoom.
    var brushColor: RGBA { drawTool == .highlighter ? MediaEditorColor.rgba(slider, alpha: 0.5) : MediaEditorColor.color(slider) }
    var brushWidth: CGFloat { CGFloat(drawWidth.rawValue) / zoom * (drawTool == .highlighter ? 2 : 1) }

    // MARK: export

    /// The document to export: a pending crop applied, no overlays.
    var exportDocument: MediaEditorSnapshot {
        var d = doc
        if mode == .crop, canCrop, let r = crop { MediaEditorGeometry.crop(&d, to: r) }
        return d
    }
}
