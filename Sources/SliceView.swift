import AppKit
import SwiftUI
import simd

struct SliceRepresentable: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    var plane: Plane
    func makeNSView(context: Context) -> SliceView { SliceView(model: model, plane: plane) }
    func updateNSView(_ view: SliceView, context: Context) { if model.panelIsVisible(ViewerPanel(plane: plane)) { view.refresh() } }
}

final class SliceView: NSView {
    let model: ViewerModel, plane: Plane
    var image: CGImage?
    var renderedIndex = -1, renderedCenter = Double.nan, renderedWindow = Double.nan
    weak var renderedVolume: CTVolume?
    var zoom = 1.0, pan = CGPoint.zero, resetToken = -1
    var dragStart = CGPoint.zero, originalPan = CGPoint.zero
    var startCenter = 0.0, startWindow = 0.0
    var measureStart: CGPoint?, measureEnd: CGPoint?
    var measurementSlice = -1
    var scrollRemainder = 0.0
    var planningDragActive = false
    var canalDragRecorded = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: ViewerModel, plane: Plane) { self.model = model; self.plane = plane; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        if resetToken != model.resetToken { zoom = 1; pan = .zero; resetToken = model.resetToken }
        if renderedVolume !== model.volume || renderedIndex != model.index(plane) || renderedCenter != model.center || renderedWindow != model.window {
            image = model.volume?.slice(plane, index: model.index(plane), center: model.center, window: model.window)
            renderedIndex = model.index(plane); renderedCenter = model.center; renderedWindow = model.window; renderedVolume = model.volume
        }
        needsDisplay = true

    }
    var imageRect: CGRect {
        guard let v = model.volume else { return .zero }
        let (w, h, sx, sy) = v.dimensions(plane)
        let pw = Double(w) * sx, ph = Double(h) * sy
        let scale = min(max(1, bounds.width - 48) / pw, max(1, bounds.height - 36) / ph) * zoom
        let rw = pw * scale, rh = ph * scale
        return CGRect(x: (bounds.width - rw) / 2 + pan.x, y: (bounds.height - rh) / 2 + pan.y, width: rw, height: rh)
    }
    func imagePoint(_ point: CGPoint) -> CGPoint {
        guard let v = model.volume else { return .zero }
        let (w, h, _, _) = v.dimensions(plane), r = imageRect
        return CGPoint(x: (point.x - r.minX) / r.width * Double(w) - 0.5, y: (point.y - r.minY) / r.height * Double(h) - 0.5)
    }
    func screenPoint(_ point: CGPoint) -> CGPoint {
        guard let v = model.volume else { return .zero }
        let (w, h, _, _) = v.dimensions(plane), r = imageRect
        return CGPoint(x: r.minX + (point.x + 0.5) / Double(w) * r.width, y: r.minY + (point.y + 0.5) / Double(h) * r.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.025, alpha: 1).setFill(); bounds.fill()
        guard let image, let volume = model.volume else { return }
        let rect = imageRect
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if model.crosshair {
            let p: CGPoint
            switch plane {
            case .axial: p = CGPoint(x: model.x, y: model.y)
            case .coronal: p = CGPoint(x: model.x, y: Double(volume.depth - 1) - model.z)
            case .sagittal: p = CGPoint(x: model.y, y: Double(volume.depth - 1) - model.z)
            }
            let q = screenPoint(p), path = NSBezierPath(); path.lineWidth = 0.75
            let gap = 6.0
            path.move(to: CGPoint(x: rect.minX, y: q.y)); path.line(to: CGPoint(x: q.x - gap, y: q.y))
            path.move(to: CGPoint(x: q.x + gap, y: q.y)); path.line(to: CGPoint(x: rect.maxX, y: q.y))
            path.move(to: CGPoint(x: q.x, y: rect.minY)); path.line(to: CGPoint(x: q.x, y: q.y - gap))
            path.move(to: CGPoint(x: q.x, y: q.y + gap)); path.line(to: CGPoint(x: q.x, y: rect.maxY))
            NSColor(calibratedRed: 0.25, green: 0.82, blue: 0.76, alpha: 0.65).setStroke(); path.stroke()
        }
        for m in model.measurements where m.plane == plane && m.slice == model.index(plane) { drawMeasurement(m.start, m.end, mm: m.mm) }
        drawPlanning(volume)
        if model.dentalLayout, plane == .axial { drawDentalCurve(volume) }
        if let a = measureStart, let b = measureEnd, measurementSlice == model.index(plane) { drawMeasurement(a, b, mm: distance(a, b)) }
        let labels: (String, String, String, String)
        switch plane { case .axial: labels = ("R", "L", "A", "P"); case .coronal: labels = ("R", "L", "S", "I"); case .sagittal: labels = ("A", "P", "S", "I") }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)]
        (labels.0 as NSString).draw(at: CGPoint(x: 8, y: bounds.midY - 6), withAttributes: attrs)
        (labels.1 as NSString).draw(at: CGPoint(x: bounds.maxX - 17, y: bounds.midY - 6), withAttributes: attrs)
        (labels.2 as NSString).draw(at: CGPoint(x: bounds.midX - 4, y: 7), withAttributes: attrs)
        (labels.3 as NSString).draw(at: CGPoint(x: bounds.midX - 4, y: bounds.maxY - 20), withAttributes: attrs)
        let (_, _, sx, _) = volume.dimensions(plane)
        let scale = rect.width / Double(image.width) / sx
        let rulerLength = 10 * scale
        let ruler = NSBezierPath(); ruler.lineWidth = 1
        ruler.move(to: CGPoint(x: 16, y: bounds.height - 26)); ruler.line(to: CGPoint(x: 16 + rulerLength, y: bounds.height - 26))
        NSColor.gray.setStroke(); ruler.stroke()
        ("10 mm" as NSString).draw(at: CGPoint(x: 16, y: bounds.height - 22), withAttributes: attrs)
    }
    func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        guard let v = model.volume else { return 0 }
        let (_, _, sx, sy) = v.dimensions(plane)
        return hypot((a.x - b.x) * sx, (a.y - b.y) * sy)
    }
    func drawMeasurement(_ a: CGPoint, _ b: CGPoint, mm: Double) {
        MeasurementOverlay.draw(from: screenPoint(a),to: screenPoint(b),mm: mm,bounds: bounds)
    }
    func drawPlanning(_ volume: CTVolume) {
        let (_, _, sx, _) = volume.dimensions(plane)
        let scale = imageRect.width / Double(image!.width) / sx
        func normal(_ p: SIMD3<Double>) -> Double { switch plane { case .axial: return p.z; case .coronal: return p.y; case .sagittal: return p.x } }
        let slicePoint = volume.origin + SIMD3(Double(Int(model.x)),Double(Int(model.y)),Double(Int(model.z))) * volume.spacing
        let slicePosition = normal(slicePoint)
        func project(_ p: SIMD3<Double>) -> CGPoint {
            let q = (p-volume.origin)/volume.spacing
            switch plane { case .axial: return screenPoint(CGPoint(x: q.x,y: q.y)); case .coronal: return screenPoint(CGPoint(x: q.x,y: Double(volume.depth-1)-q.z)); case .sagittal: return screenPoint(CGPoint(x: q.y,y: Double(volume.depth-1)-q.z)) }
        }
        func clippedSegment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, radius: Double, color: NSColor) {
            let start = normal(a), delta = normal(b)-start
            var lo = 0.0, hi = 1.0
            if abs(delta) < 1e-10 { if abs(start-slicePosition) > radius { return } }
            else {
                let t0 = (slicePosition-radius-start)/delta, t1 = (slicePosition+radius-start)/delta
                lo = max(0,min(t0,t1)); hi = min(1,max(t0,t1)); if lo > hi { return }
            }
            let p = project(a+(b-a)*lo), q = project(a+(b-a)*hi), thickness = max(2,radius*2*scale)
            if hypot(p.x-q.x,p.y-q.y) < 0.1 {
                color.withAlphaComponent(0.5).setFill(); NSBezierPath(ovalIn: CGRect(x: p.x-thickness/2,y: p.y-thickness/2,width: thickness,height: thickness)).fill()
                color.setStroke(); NSBezierPath(ovalIn: CGRect(x: p.x-thickness/2,y: p.y-thickness/2,width: thickness,height: thickness)).stroke()
            } else {
                let line = NSBezierPath(); line.move(to: p); line.line(to: q); line.lineWidth = thickness; line.lineCapStyle = .round
                color.withAlphaComponent(0.5).setStroke(); line.stroke()
                line.lineWidth = 1; color.setStroke(); line.stroke()
            }
        }
        if model.showXelisCanals, let project = model.xelisProject {
            for canal in project.canals {
                for (a,b) in zip(canal.points,canal.points.dropFirst()) { clippedSegment(a,b,radius: XelisProject.displayRadius,color: .systemGreen) }
            }
        }
        guard model.showPlanning else { return }
        let canals = model.planning.canals
        for canal in canals where canal.visible {
            let rgb = canal.color.rgb, color = NSColor(calibratedRed: rgb.x,green: rgb.y,blue: rgb.z,alpha: 1)
            let path = canal.path
            for (a,b) in zip(path.points,path.points.dropFirst()) { clippedSegment(a,b,radius: canal.diameter/2,color: color) }
            do {
                for (i,point) in canal.points.enumerated() where abs(normal(point.vector)-slicePosition) <= canal.diameter/2 {
                    let p = project(point.vector)
                    let selected = canal.id == model.selectedCanalID && i == model.selectedCanalPoint
                    let radius = selected ? 4.5 : 2.5
                    color.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x-radius,y: p.y-radius,width: radius*2,height: radius*2)).fill()
                    if selected { NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: CGRect(x: p.x-6,y: p.y-6,width: 12,height: 12)); ring.lineWidth = 1.5; ring.stroke() }
                    if model.tool == .canal && canal.id == model.selectedCanalID {
                        (String(i+1) as NSString).draw(at: CGPoint(x: p.x+7,y: p.y-14),withAttributes: [.font: NSFont.systemFont(ofSize: 10,weight: .semibold),.foregroundColor: color,.backgroundColor: NSColor.black.withAlphaComponent(0.7)])
                    }
                }
            }
        }
        for implant in model.planning.implants {
            let color = implant.id == model.selectedImplantID ? NSColor.systemTeal : NSColor.systemBlue
            clippedSegment(implant.entry.vector,implant.apex,radius: implant.diameter/2,color: color)
            if abs(normal(implant.entry.vector)-slicePosition) <= implant.diameter/2 {
                let p = project(implant.entry.vector), path = NSBezierPath(ovalIn: CGRect(x: p.x-4,y: p.y-4,width: 8,height: 8)); color.setStroke(); path.lineWidth = 2; path.stroke()
                (implant.name as NSString).draw(at: CGPoint(x: p.x+7,y: p.y-17),withAttributes: [.font: NSFont.systemFont(ofSize: 10,weight: .medium),.foregroundColor: color,.backgroundColor: NSColor.black.withAlphaComponent(0.7)])
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p; originalPan = pan; startCenter = model.center; startWindow = model.window
        planningDragActive = false; canalDragRecorded = false
        if event.clickCount == 2 { if model.tool == .canal { return }; zoom = 1; pan = .zero; needsDisplay = true; return }
        guard imageRect.contains(p), model.volume != nil, !event.modifierFlags.contains(.option) else { return }
        switch model.tool {
        case .navigate: model.navigate(plane, point: imagePoint(p))
        case .measure: measureStart = imagePoint(p); measureEnd = measureStart; measurementSlice = model.index(plane); needsDisplay = true
        case .window: break
        case .arch:
            guard plane == .axial, model.xelisProject == nil else { return }
            if model.archPoints.count < 2 {
                let q = imagePoint(p)
                model.archPoints.append(q); model.rebuildDentalCurve(); return
            }
            model.editingArchPoint = model.archPoints.indices.min { a,b in
                let pa = screenPoint(model.archPoints[a]), pb = screenPoint(model.archPoints[b])
                return hypot(pa.x-p.x,pa.y-p.y) < hypot(pb.x-p.x,pb.y-p.y)
            }
            if let i = model.editingArchPoint {
                let q = screenPoint(model.archPoints[i])
                if hypot(q.x-p.x,q.y-p.y) > 16 { model.editingArchPoint = nil; model.archPoints.append(imagePoint(p)); model.rebuildDentalCurve() }
            }
        case .implant: if let point = model.patientPoint(plane,imagePoint: imagePoint(p)) { model.positionImplant(at: point); planningDragActive = true }
        case .canal:
            guard model.showPlanning, let point = model.patientPoint(plane,imagePoint: imagePoint(p)) else { return }
            if let hit = canalPointHit(p) {
                model.selectedCanalID = hit.0; model.selectCanalPoint(hit.1,centerViews: false)
                planningDragActive = true
            } else if model.canalInteraction == .draw {
                planningDragActive = model.addCanalPoint(point); canalDragRecorded = planningDragActive
            } else if model.canalInteraction == .insert, let hit = canalSegmentHit(p) {
                model.selectedCanalID = hit.0
                planningDragActive = model.addCanalPoint(point,after: hit.1); canalDragRecorded = planningDragActive
            }

        }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) { pan = CGPoint(x: originalPan.x + p.x - dragStart.x, y: originalPan.y + p.y - dragStart.y); needsDisplay = true; return }
        switch model.tool {
        case .navigate: model.navigate(plane, point: imagePoint(p))
        case .measure: if measureStart != nil { let q = CGPoint(x: min(imageRect.maxX, max(imageRect.minX, p.x)), y: min(imageRect.maxY, max(imageRect.minY, p.y))); measureEnd = imagePoint(q); needsDisplay = true }
        case .window: model.center = min(3500, max(-1200, startCenter - (p.y - dragStart.y) * 5)); model.window = min(7000, max(1, startWindow + (p.x - dragStart.x) * 10))
        case .arch: if plane == .axial, let i = model.editingArchPoint { model.moveArchPoint(i,to: imagePoint(p)) }
        case .implant: if planningDragActive, let point = model.patientPoint(plane,imagePoint: imagePoint(p)) { model.positionImplant(at: point) }
        case .canal: if planningDragActive, let point = model.patientPoint(plane,imagePoint: imagePoint(p)) {
            if !canalDragRecorded { model.canalHistory.record(model.planning.canals); canalDragRecorded = true }
            model.moveCanalPoint(point,in: plane,record: false)
        }
        }
    }
    override func mouseUp(with event: NSEvent) {
        if let a = measureStart, let b = measureEnd, measurementSlice == model.index(plane), distance(a, b) > 0.01 {
            model.measurements.append(SliceMeasurement(plane: plane, slice: measurementSlice, start: a, end: b, mm: distance(a, b)))
        }
        measureStart = nil; measureEnd = nil; needsDisplay = true
        planningDragActive = false
        model.editingArchPoint = nil
    }
    func canalNormal(_ p: SIMD3<Double>) -> Double {
        switch plane { case .axial: return p.z; case .coronal: return p.y; case .sagittal: return p.x }
    }
    func canalProjection(_ p: SIMD3<Double>) -> CGPoint {
        guard let v = model.volume else { return .zero }
        let q = (p-v.origin)/v.spacing
        switch plane { case .axial: return screenPoint(CGPoint(x: q.x,y: q.y)); case .coronal: return screenPoint(CGPoint(x: q.x,y: Double(v.depth-1)-q.z)); case .sagittal: return screenPoint(CGPoint(x: q.y,y: Double(v.depth-1)-q.z)) }
    }
    var slicePosition: Double {
        guard let v = model.volume else { return 0 }
        let p = v.origin+SIMD3(Double(Int(model.x)),Double(Int(model.y)),Double(Int(model.z)))*v.spacing
        return canalNormal(p)
    }
    func canalPointHit(_ click: CGPoint) -> (UUID,Int)? {
        var closest = 10.0, result: (UUID,Int)?
        for canal in model.planning.canals where canal.visible {
            for (i,point) in canal.points.enumerated() where abs(canalNormal(point.vector)-slicePosition) <= canal.diameter/2 {
                let p = canalProjection(point.vector), distance = hypot(p.x-click.x,p.y-click.y)
                if distance < closest { closest = distance; result = (canal.id,i) }
            }
        }
        return result
    }
    func canalSegmentHit(_ click: CGPoint) -> (UUID,Int)? {
        var closest = 10.0, result: (UUID,Int)?
        for canal in model.planning.canals where canal.visible {
            let path = canal.path
            for i in 0..<max(0,path.points.count-1) {
                let a = path.points[i], b = path.points[i+1], start = canalNormal(a), delta = canalNormal(b)-start
                var lo = 0.0, hi = 1.0
                if abs(delta) < 1e-10 { if abs(start-slicePosition) > canal.diameter/2 { continue } }
                else {
                    let t0 = (slicePosition-canal.diameter/2-start)/delta, t1 = (slicePosition+canal.diameter/2-start)/delta
                    lo = max(0,min(t0,t1)); hi = min(1,max(t0,t1)); if lo > hi { continue }
                }
                let p = canalProjection(a+(b-a)*lo), q = canalProjection(a+(b-a)*hi)
                let d = SIMD2<Double>(q.x-p.x,q.y-p.y), w = SIMD2<Double>(click.x-p.x,click.y-p.y)
                let t = min(1,max(0,simd_dot(w,d)/max(1e-12,simd_dot(d,d))))
                let distance = simd_length(w-d*t)
                if distance < closest { closest = distance; result = (canal.id,i/path.subdivisions) }
            }
        }
        return result
    }
    override func keyDown(with event: NSEvent) {
        if model.tool == .canal && [51,117].contains(event.keyCode) { model.deleteCanalPoint(); return }
        super.keyDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { zoom = min(8, max(0.3, zoom * exp(event.scrollingDeltaY * 0.025))); needsDisplay = true; return }
        scrollRemainder += Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.15 : 1)
        let delta = Int(scrollRemainder)
        if delta != 0 { model.move(plane, delta: delta); scrollRemainder -= Double(delta) }
    }
    override func magnify(with event: NSEvent) { zoom = min(8, max(0.3, zoom * (1 + event.magnification))); needsDisplay = true }
}
