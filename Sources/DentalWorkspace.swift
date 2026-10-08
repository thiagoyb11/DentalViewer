import AppKit
import SwiftUI
import simd

extension ViewerModel {
    func initializeDentalCurve() {
        guard let v = volume else { return }
        panoramicOffset = 0
        if let project = xelisProject {
            archPoints = project.arch.controls.map { CGPoint(x: ($0.x-v.origin.x)/v.spacing.x,y: ($0.y-v.origin.y)/v.spacing.y) }
            archCurve = ArchCurve(saved: project.arch,origin: v.origin)
            archDistance = (archCurve?.length ?? 0)/2
        } else { archPoints = []; archCurve = nil; archDistance = 0 }
    }
    func rebuildDentalCurve() {
        guard let v = volume else { archCurve = nil; return }
        archCurve = try? ArchCurve(points: archPoints,spacing: SIMD2(v.spacing.x,v.spacing.y))
        archDistance = min(archDistance,archCurve?.length ?? 0)
    }
    func moveArchPoint(_ index: Int, to point: CGPoint) {
        guard let v = volume, archPoints.indices.contains(index), xelisProject == nil else { return }
        archPoints[index] = CGPoint(x: min(Double(v.width-1),max(0,point.x)),y: min(Double(v.height-1),max(0,point.y)))
        rebuildDentalCurve()
    }
    func transverseIndices(_ curve: ArchCurve) -> [Int] {
        (-4...4).map { offset in min(curve.samples.count-1,max(0,curve.index(at: archDistance+Double(offset)*transverseSpacing))) }
    }
    func setArchDistance(_ distance: Double) {
        guard let curve = archCurve, let v = volume else { return }
        archDistance = min(curve.length,max(0,distance))
        let p = curve.samples[min(curve.samples.count-1,curve.index(at: archDistance))].position
        x = min(Double(v.width-1),max(0,p.x/v.spacing.x)); y = min(Double(v.height-1),max(0,p.y/v.spacing.y))
    }
}

extension SliceView {
    func drawDentalCurve(_ volume: CTVolume) {
        guard let curve = model.archCurve else { return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: imageRect).addClip()
        func project(_ p: SIMD2<Double>) -> CGPoint { screenPoint(CGPoint(x: p.x/volume.spacing.x,y: p.y/volume.spacing.y)) }
        let line = NSBezierPath()
        for (i,sample) in curve.samples.enumerated() { if i == 0 { line.move(to: project(sample.position)) } else { line.line(to: project(sample.position)) } }
        NSColor.systemBlue.setStroke(); line.lineWidth = 1.5; line.stroke()
        for distance in stride(from: 0.0,through: curve.length,by: 1) {
            let index = min(curve.samples.count-1,curve.index(at: distance))
            let sample = curve.samples[index], half = sample.normal*model.transverseField/2
            let cut = NSBezierPath(); cut.move(to:project(sample.position-half)); cut.line(to:project(sample.position+half))
            (Int(distance).isMultiple(of:5) ? NSColor.systemYellow.withAlphaComponent(0.65) : NSColor.systemBlue.withAlphaComponent(0.45)).setStroke()
            cut.lineWidth = 0.5; cut.stroke()
        }
        for (i,index) in model.transverseIndices(curve).enumerated() {
            let sample = curve.samples[index], half = sample.normal*model.transverseField/2
            let cut = NSBezierPath(); cut.move(to: project(sample.position-half)); cut.line(to: project(sample.position+half))
            (i == 4 ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.7)).setStroke()
            cut.lineWidth = i == 4 ? 2 : 0.75; cut.stroke()
        }
        for point in model.archPoints {
            let p = screenPoint(point), r = CGRect(x: p.x-3.5,y: p.y-3.5,width: 7,height: 7)
            NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: r).fill()
            NSColor.white.setStroke(); NSBezierPath(ovalIn: r).stroke()
        }
        // The cyan surface and its slab limits are view settings, independent of the original arch.
        if model.panoramicOffset != 0 || model.panoramicThickness > 0 {
            for offset in [model.panoramicOffset-model.panoramicThickness/2,model.panoramicOffset+model.panoramicThickness/2,model.panoramicOffset] {
                let path = NSBezierPath()
                for (i,sample) in curve.samples.enumerated() {
                    let p = curve.localPosition(sample: sample,height: model.z*volume.spacing.z,offset: offset)
                    let q = project(SIMD2(p.x,p.y))
                    if i == 0 { path.move(to: q) } else { path.line(to: q) }
                }
                let center = offset == model.panoramicOffset
                NSColor.systemTeal.withAlphaComponent(center ? 0.95 : 0.4).setStroke()
                path.lineWidth = center ? 1.5 : 0.7
                if !center { path.setLineDash([3,3],count: 2,phase: 0) }
                path.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct DentalReformatPanel: View {
    @ObservedObject var model: ViewerModel
    var panoramic: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panoramic ? "Panorámica curva" : (model.enlargedTransverseIndex == nil ? "Secciones transversales" : "Sección transversal")).font(.system(size: 12,weight: .medium))
                Spacer()
                if panoramic {
                    Button { model.tool = .measure } label: { Label("Medir",systemImage: "ruler") }
                        .controlSize(.small).help("Arrastrá sobre la panorámica para medir en milímetros")
                    Text("Espesor").font(.system(size: 10))
                    Slider(value: $model.panoramicThickness,in: 0...10,step: 0.5).frame(width: 70).controlSize(.mini)
                        .accessibilityLabel("Espesor panorámico").help("Espesor de la capa promediada alrededor de la profundidad elegida")
                    Text(String(format: "%.1f mm",model.panoramicThickness)).font(.system(size: 10)).monospacedDigit()
                } else {
                    Text("Paso").font(.system(size: 10))
                    Picker("Paso entre secciones",selection: $model.transverseSpacing) {
                        Text("0.5 mm").tag(0.5); Text("1 mm").tag(1.0); Text("2 mm").tag(2.0)
                    }.labelsHidden().frame(width: 75).controlSize(.mini)
                }
                PanelExpandButton(model: model,panel: panoramic ? .panoramic : .transverse)
            }.padding(.horizontal,10).padding(.vertical,7)
            if panoramic {
                HStack(spacing: 7) {
                    Text("Profundidad").font(.system(size: 10))
                    Button { model.movePanoramicDepth(-0.1) } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Disminuir profundidad panorámica")
                    Slider(value: $model.panoramicOffset,in: -10...10,step: 0.1)
                        .accessibilityLabel("Profundidad panorámica").help("Desplaza la superficie curva respecto del arco original, sin modificarlo")
                    Button { model.movePanoramicDepth(0.1) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Aumentar profundidad panorámica")
                    Text(String(format: "%+.1f mm",model.panoramicOffset)).font(.system(size: 10)).monospacedDigit().frame(width: 57)
                    Button { model.panoramicOffset = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .accessibilityLabel("Restablecer profundidad panorámica").help("Volver al arco original: 0 mm")
                }.controlSize(.mini).padding(.horizontal,10).padding(.bottom,5)
            }
            DentalImagesRepresentable(model: model,panoramic: panoramic)
            if panoramic, let curve = model.archCurve {
                HStack {
                    Slider(value: Binding(get: { model.archDistance },set: { model.setArchDistance($0) }),in: 0...curve.length)
                    Text(String(format: "%.1f / %.1f mm",model.archDistance,curve.length)).font(.system(size: 10)).monospacedDigit()
                }.padding(.horizontal,10).controlSize(.small)
                Text(model.dentalToolHint(panoramic: true))
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Text("⇧ + rueda: profundidad · axial: superficie en cian · al cambiar profundidad se borran sus medidas")
                    .font(.system(size: 9)).foregroundColor(.secondary).padding(.bottom,5)
            } else {
                Text(model.dentalToolHint(panoramic: false)).font(.system(size: 9)).foregroundColor(.secondary).padding(5)
            }
        }.background(Color(white: 0.11)).cornerRadius(7).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.07)))
    }
}
struct DentalImagesRepresentable: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    let panoramic: Bool
    func makeNSView(context: Context) -> DentalImagesView { DentalImagesView(model: model,panoramic: panoramic) }
    func updateNSView(_ view: DentalImagesView,context: Context) { if model.panelIsVisible(panoramic ? .panoramic : .transverse) { view.refresh() } }
}
final class DentalRenderRequest {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
final class DentalImagesView: NSView {
    let model: ViewerModel
    let panoramic: Bool
    var images: [CGImage] = [], indices: [Int] = []
    var previousKey = ""
    weak var previousVolume: CTVolume?
    var renderGeneration = 0
    let renderQueue = DispatchQueue(label: "local.dentalviewer.reformat",qos: .userInitiated)
    var renderRequest: DentalRenderRequest?
    var imageRevision = -1
    var renderedCurve: ArchCurve?
    var renderedArchCurve: ArchCurve?
    weak var renderedVolume: CTVolume?
    var renderedField = 25.0
    var measureStart: CGPoint?, measureEnd: CGPoint?
    var measurementRevision = -1
    var dragCell: Int?, dragSection: Int?, dragTool: Tool?
    var dragStart = CGPoint.zero
    var startCenter = 0.0, startWindow = 0.0
    var canalDragRecorded = false
    var planningDragActive = false
    var geometryRevision: Int { panoramic ? model.panoramicRevision : model.archRevision }
    var displayCurve: ArchCurve? { panoramic ? model.panoramicCurve : model.archCurve }
    var drawingCurve: ArchCurve? { renderedCurve ?? displayCurve }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(model: ViewerModel,panoramic: Bool) { self.model = model; self.panoramic = panoramic; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        if let dragTool, dragTool != model.tool || (dragTool != .window && measurementRevision != geometryRevision) { cancelMeasurement() }
        guard let v = model.volume, let curve = displayCurve else {
            renderRequest?.cancel(); renderGeneration += 1; previousKey = ""; clearRenderedImages(); needsDisplay = true; return
        }
        let currentIndices = model.transverseIndices(curve)
        let key = "\(geometryRevision),\(model.center),\(model.window),\(panoramic ? model.panoramicThickness : 0),\(model.transverseField),\(panoramic ? [] : currentIndices)"
        if key != previousKey || previousVolume !== v {
            previousKey = key; previousVolume = v
            renderGeneration += 1; let generation = renderGeneration
            renderRequest?.cancel()
            let request = DentalRenderRequest(); renderRequest = request
            // Keep the complete previous frame while sampling. A different study must not retain it.
            if renderedVolume !== v { clearRenderedImages() }
            let originalCurve = model.archCurve
            let center = model.center, window = model.window, thickness = model.panoramicThickness, field = model.transverseField, revision = geometryRevision
            renderQueue.asyncAfter(deadline: .now()+0.06) {
                guard !request.isCancelled else { return }
                let images = self.panoramic ? [v.panoramic(curve: curve,thickness: thickness,maximum: false,center: center,window: window,shouldCancel: { request.isCancelled })].compactMap { $0 }
                    : currentIndices.compactMap { request.isCancelled ? nil : v.transverse(curve: curve,index: $0,field: field,center: center,window: window) }
                DispatchQueue.main.async {
                    guard self.renderGeneration == generation, !request.isCancelled, !images.isEmpty else { return }
                    self.images = images; self.indices = currentIndices; self.imageRevision = revision
                    self.renderedCurve = curve; self.renderedArchCurve = originalCurve; self.renderedVolume = v; self.renderedField = field
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }
    func clearRenderedImages() {
        images = []; indices = []; imageRevision = -1
        renderedCurve = nil; renderedArchCurve = nil; renderedVolume = nil
    }
    func cellRect(_ i: Int) -> CGRect {
        if panoramic { return bounds.insetBy(dx: 5,dy: 5) }
        if let selected = model.enlargedTransverseIndex { return i == selected ? bounds.insetBy(dx: 5,dy: 5) : .zero }
        let w = bounds.width/3, h = bounds.height/3
        return CGRect(x: Double(i%3)*w+1,y: Double(i/3)*h+1,width: max(1,w-2),height: max(1,h-2))
    }
    func imageRect(_ i: Int) -> CGRect {
        guard let v = renderedVolume ?? model.volume, let curve = drawingCurve else { return .zero }
        let cell = cellRect(i).insetBy(dx: 10,dy: panoramic ? 8 : 14)
        let physicalWidth: Double
        if panoramic { physicalWidth = curve.imageWidth }
        else {
            guard images.indices.contains(i), images[i].width > 1 else { return .zero }
            // Field spans endpoint centres; include half a pixel at both image edges.
            physicalWidth = renderedField*Double(images[i].width)/Double(images[i].width-1)
        }
        let physicalHeight = Double(v.depth)*v.spacing.z
        // During layout a view can briefly have no drawable area, even with a window minimum.
        guard cell.width.isFinite, cell.height.isFinite, cell.width > 0, cell.height > 0,
              physicalWidth.isFinite, physicalHeight.isFinite, physicalWidth > 0, physicalHeight > 0 else { return .zero }
        let scale = min(cell.width/physicalWidth,cell.height/(panoramic ? physicalHeight : min(physicalHeight,renderedField)))
        let imageHeight = physicalHeight*scale
        let row = Double(v.depth-1)-model.z
        let top = panoramic ? cell.midY-imageHeight/2 : cell.midY-(row+0.5)/Double(v.depth)*imageHeight
        return CGRect(x: cell.midX-physicalWidth*scale/2,y: top,width: physicalWidth*scale,height: imageHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.025,alpha: 1).setFill(); bounds.fill()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize: 9,weight: .regular),.foregroundColor:NSColor.lightGray]
        for (i,image) in images.enumerated() {
            if !panoramic, let selected = model.enlargedTransverseIndex, i != selected { continue }
            let r = imageRect(i), cell = cellRect(i)
            guard r.width > 0, r.height > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: cell.insetBy(dx: panoramic ? 0 : 10,dy: panoramic ? 0 : 14)).addClip()
            NSImage(cgImage: image,size: r.size).draw(in: r,from: .zero,operation: .copy,fraction: 1,respectFlipped: true,hints: [.interpolation:NSImageInterpolation.high])
            drawXelisCanals(in: r,cell: i)
            drawDentalPlanning(in: r,cell: i)
            if !panoramic, let curve = renderedCurve, indices.indices.contains(i) {
                NSGraphicsContext.restoreGraphicsState()
                (String(format: "%.1f mm",curve.distances[indices[i]]) as NSString).draw(at: CGPoint(x: cell.minX+5,y: cell.minY+3),withAttributes: attrs)
                ("B" as NSString).draw(at: CGPoint(x: cell.minX+2,y: cell.midY),withAttributes: attrs)
                ("L" as NSString).draw(at: CGPoint(x: cell.maxX-9,y: cell.midY),withAttributes: attrs)
                ("S" as NSString).draw(at: CGPoint(x: r.midX,y: cell.minY+3),withAttributes: attrs)
                ("I" as NSString).draw(at: CGPoint(x: r.midX,y: cell.maxY-13),withAttributes: attrs)
                (i == 4 ? NSColor.systemOrange : NSColor.darkGray).setStroke()
                NSBezierPath(rect: cell).stroke()
                let ruler = NSBezierPath(); ruler.move(to:CGPoint(x:cell.minX+7,y:cell.maxY-7)); ruler.line(to:CGPoint(x:cell.minX+7+5*r.width/renderedField,y:cell.maxY-7)); NSColor.lightGray.setStroke(); ruler.stroke()
                ("5 mm" as NSString).draw(at:CGPoint(x:cell.minX+9,y:cell.maxY-17),withAttributes:attrs)
                if model.enlargedTransverseIndex == nil {
                    let icon = expansionRect(i)
                    let path = NSBezierPath(); path.lineWidth = 1
                    path.move(to: CGPoint(x: icon.minX+3,y: icon.minY+8)); path.line(to: CGPoint(x: icon.minX+3,y: icon.minY+3)); path.line(to: CGPoint(x: icon.minX+8,y: icon.minY+3))
                    path.move(to: CGPoint(x: icon.maxX-8,y: icon.maxY-3)); path.line(to: CGPoint(x: icon.maxX-3,y: icon.maxY-3)); path.line(to: CGPoint(x: icon.maxX-3,y: icon.maxY-8))
                    NSColor.lightGray.setStroke(); path.stroke()
                }
            } else {
                NSGraphicsContext.restoreGraphicsState()
            }
            if !panoramic { drawTransverseMeasurements(in: r,cell: i) }
            if let v = model.volume, model.crosshair {
                let row = Double(v.depth-1)-model.z
                let y = r.minY+(row+0.5)/Double(image.height)*r.height
                let line = NSBezierPath(); line.move(to: CGPoint(x: r.minX,y: y)); line.line(to: CGPoint(x: r.maxX,y: y)); line.lineWidth = 0.6
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:cell.insetBy(dx:0,dy:14)).addClip()
                NSColor.systemTeal.withAlphaComponent(0.75).setStroke(); line.stroke(); NSGraphicsContext.restoreGraphicsState()
            }
            if panoramic, let curve = renderedArchCurve {
                let x = r.minX+(curve.column(atDistance: model.archDistance)+0.5)/Double(curve.samples.count)*r.width
                let line = NSBezierPath(); line.move(to: CGPoint(x: x,y: r.minY)); line.line(to: CGPoint(x: x,y: r.maxY))
                NSColor.systemOrange.setStroke(); line.stroke()
                let metric = drawingCurve ?? curve
                let ticks = NSBezierPath()
                for mm in stride(from: 0.0,through: metric.length,by: 1) {
                    let x = r.minX+(metric.column(atDistance: mm)+0.5)/Double(metric.samples.count)*r.width
                    let major = Int(mm).isMultiple(of:10)
                    ticks.move(to: CGPoint(x: x,y: r.maxY)); ticks.line(to: CGPoint(x: x,y: r.maxY-(major ? 8 : 3)))
                    if major {
                        let label = String(format:"%.0f",mm) as NSString
                        let labelWidth = label.size(withAttributes: attrs).width
                        label.draw(at: CGPoint(x: min(r.maxX-labelWidth,max(r.minX,x-labelWidth/2)),y: r.maxY-21),withAttributes: attrs)
                    }
                }
                NSColor.lightGray.setStroke(); ticks.lineWidth = 0.7; ticks.stroke()
                ("Recorrido del arco · mm" as NSString).draw(at: CGPoint(x: r.minX+5,y: max(cell.minY+2,r.minY-14)),withAttributes: attrs)
                if let v = model.volume {
                    let barHeight = 10/(Double(v.depth)*v.spacing.z)*r.height
                    let x = cell.maxX-48, bottom = min(r.maxY-30,cell.maxY-30)
                    let bar = NSBezierPath()
                    bar.move(to: CGPoint(x: x,y: bottom)); bar.line(to: CGPoint(x: x,y: bottom-barHeight))
                    for y in [bottom,bottom-barHeight] { bar.move(to: CGPoint(x: x-3,y: y)); bar.line(to: CGPoint(x: x+3,y: y)) }
                    NSColor.white.setStroke(); bar.lineWidth = 1; bar.stroke()
                    ("10 mm" as NSString).draw(at: CGPoint(x: x-15,y: bottom+3),withAttributes: attrs)
                }
            }
        }
        if panoramic, let curve = displayCurve, let v = model.volume, imageRevision == geometryRevision {
            let rect = imageRect(0)
            func draw(_ a: CGPoint,_ b: CGPoint,_ mm: Double) {
                MeasurementOverlay.draw(from: PanoramicMeasurementGeometry.screenPoint(a,in: rect,columns: curve.samples.count,rows: v.depth),
                                        to: PanoramicMeasurementGeometry.screenPoint(b,in: rect,columns: curve.samples.count,rows: v.depth),mm: mm,bounds: bounds)
            }
            for m in model.panoramicMeasurements { draw(m.start,m.end,m.mm) }
            if let a = measureStart, let b = measureEnd, measurementRevision == geometryRevision {
                draw(a,b,PanoramicMeasurementGeometry.distance(a,b,curve: curve,verticalSpacing: v.spacing.z))
            }
        }
    }
    func expansionRect(_ index: Int) -> CGRect { let cell = cellRect(index); return CGRect(x: cell.maxX-24,y: cell.minY+2,width: 20,height: 20) }
    func cancelMeasurement() { measureStart = nil; measureEnd = nil; measurementRevision = -1; dragCell = nil; dragSection = nil; dragTool = nil; planningDragActive = false }
    func measurementPoint(_ screen: CGPoint) -> CGPoint? {
        guard panoramic, let v = model.volume, let curve = displayCurve, images.first != nil,
              imageRevision == geometryRevision, previousVolume === v else { return nil }
        let rect = imageRect(0)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return PanoramicMeasurementGeometry.imagePoint(screen,in: rect,columns: curve.samples.count,rows: v.depth)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelMeasurement()
        guard model.archCurve != nil else { return }
        let p = convert(event.locationInWindow,from: nil)
        if !panoramic, model.enlargedTransverseIndex == nil,
           let i = images.indices.first(where: { expansionRect($0).contains(p) }) {
            model.enlargedTransverseIndex = i; model.focusedPanel = .transverse; needsDisplay = true; return
        }
        guard !event.modifierFlags.contains(.option) else { return }
        beginDentalInteraction(at: p)
    }
    override func mouseDragged(with event: NSEvent) {
        dragDentalInteraction(to: convert(event.locationInWindow,from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        endDentalInteraction(at: convert(event.locationInWindow,from: nil))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelMeasurement(); needsDisplay = true }
        else if model.tool == .canal && [51,117].contains(event.keyCode) { model.deleteCanalPoint() }
        else { super.keyDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard dragTool == nil else { return }
        if panoramic, event.modifierFlags.contains(.shift) {
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            model.movePanoramicDepth(Double(delta)*(event.hasPreciseScrollingDeltas ? 0.02 : 0.1))
        } else { model.setArchDistance(model.archDistance+Double(event.scrollingDeltaY)*(event.hasPreciseScrollingDeltas ? 0.1 : model.transverseSpacing)) }
    }
}

struct IntensityPanel: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading,spacing: 3) {
                Text("Intensidad · clic: umbral 3D").font(.system(size: 10)).foregroundColor(.secondary)
                HistogramRepresentable(model: model)
            }
            VStack(spacing: 6) {
                HStack { Text("Centro"); Slider(value: $model.center,in: -1200...3500); Text(String(format:"%.0f",model.center)).frame(width: 40) }
                HStack { Text("Ventana"); Slider(value: $model.window,in: 1...7000); Text(String(format:"%.0f",model.window)).frame(width: 40) }
            }.font(.system(size: 10)).controlSize(.small).frame(width: 250)
        }.padding(10).frame(height: 85).background(Color(white: 0.1)).cornerRadius(7)
    }
}
struct HistogramRepresentable: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    func makeNSView(context: Context) -> HistogramView { HistogramView(model:model) }
    func updateNSView(_ view: HistogramView,context: Context) { view.refresh() }
}
final class HistogramView: NSView {
    let model: ViewerModel
    weak var loadedVolume: CTVolume?
    var counts = [Int](repeating: 0,count: 256)
    init(model: ViewerModel) { self.model = model; super.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError() }
    func refresh() {
        if let v = model.volume, loadedVolume !== v {
            loadedVolume = v
            DispatchQueue.global(qos:.userInitiated).async {
                var histogram = [Int](repeating:0,count:256)
                for z in stride(from:0,to:v.depth,by:4) { for y in stride(from:0,to:v.height,by:4) { for x in stride(from:0,to:v.width,by:4) {
                    let bin = min(255,max(0,Int((Double(v.value(x:x,y:y,z:z))+1200)/5200*256)))
                    histogram[bin] += 1
                } } }
                DispatchQueue.main.async { guard self.loadedVolume === v else { return }; self.counts = histogram; self.needsDisplay = true }
            }
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let h = max(1,bounds.height-14), peak = Double(max(1,counts.max() ?? 1))
        func pixel(_ value:Double) -> Double { (value+1200)/5200*bounds.width }
        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        CGRect(x:pixel(model.center-model.window/2),y:14,width:model.window/5200*bounds.width,height:h).fill()
        let path = NSBezierPath(); path.move(to:CGPoint(x:0,y:14))
        for (i,n) in counts.enumerated() { path.line(to:CGPoint(x:Double(i)/255*bounds.width,y:14+sqrt(Double(n)/peak)*h)) }
        path.line(to:CGPoint(x:bounds.width,y:14)); path.close(); NSColor.systemBlue.withAlphaComponent(0.6).setFill(); path.fill()
        let line = NSBezierPath(); line.move(to:CGPoint(x:pixel(model.threshold),y:14)); line.line(to:CGPoint(x:pixel(model.threshold),y:bounds.height))
        NSColor.systemOrange.setStroke(); line.stroke()
        for value in stride(from:-1000,through:4000,by:1000) {
            ("\(value)" as NSString).draw(at:CGPoint(x:pixel(Double(value)),y:1),withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.lightGray])
        }
    }
    override func mouseDown(with event:NSEvent) { let p = convert(event.locationInWindow,from:nil); model.threshold = min(2500,max(-500,p.x/max(1,bounds.width)*5200-1200)) }
    override func mouseDragged(with event:NSEvent) { mouseDown(with:event) }
}
