import AppKit
import SwiftUI
import simd

struct CanalReviewPanel: View {
    @ObservedObject var model: ViewerModel
    var canal: NerveCanal? { model.reviewedCanal }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.reviewSourceIndex == nil ? "Revisión del canal" : (model.reviewedCanal?.name ?? "Canal original Xelis")).font(.system(size: 12,weight: .medium))
                Spacer()
                Button("Volver a 3D") { model.reviewCanal = false }.controlSize(.small)
                PanelExpandButton(model: model,panel: .volume)
            }.padding(12)
            Picker("Plano de revisión",selection: $model.reviewLongitudinal) {
                Text("Perpendicular").tag(false); Text("Longitudinal").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal,12)
            CanalReviewRepresentable(model: model)
            if let canal, canal.path.length > 0.001 {
                let length = canal.path.length
                HStack {
                    Button { setDistance(model.reviewDistance-1) } label: { Image(systemName: "chevron.left") }.help("Retroceder 1 mm")
                    Slider(value: Binding(get: { min(length,model.reviewDistance) },set: { setDistance($0) }),in: 0...length)
                    Button { setDistance(model.reviewDistance+1) } label: { Image(systemName: "chevron.right") }.help("Avanzar 1 mm")
                    Text(String(format: "%.1f / %.1f mm",min(length,model.reviewDistance),length)).font(.system(size: 10,design: .monospaced))
                }.padding(.horizontal,12).controlSize(.small)
                HStack {
                    Text("Campo").font(.system(size: 10)); Slider(value: $model.reviewField,in: 10...50,step: 1)
                    Text(String(format: "%.0f mm",model.reviewField)).font(.system(size: 10))
                }.padding(.horizontal,12).padding(.bottom,10).controlSize(.small)
            }
        }.background(Color(white: 0.11)).cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07)))
    }
    func setDistance(_ distance: Double) {
        guard let canal, let v = model.volume else { return }
        model.reviewDistance = min(canal.path.length,max(0,distance))
        if let frame = canal.path.frame(at: model.reviewDistance) {
            let q = (frame.center-v.origin)/v.spacing
            model.x = min(Double(v.width-1),max(0,q.x)); model.y = min(Double(v.height-1),max(0,q.y)); model.z = min(Double(v.depth-1),max(0,q.z))
        }
    }
}
struct CanalReviewRepresentable: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    func makeNSView(context: Context) -> CanalReviewView { CanalReviewView(model: model) }
    func updateNSView(_ view: CanalReviewView, context: Context) { if model.panelIsVisible(.volume) { view.refresh() } }
}
final class CanalReviewView: NSView {
    let model: ViewerModel
    var image: CGImage?
    var lastCanal: NerveCanal?, lastField = Double.nan, lastDistance = Double.nan, lastCenter = Double.nan, lastWindow = Double.nan
    var lastLongitudinal = false
    weak var lastVolume: CTVolume?
    override var isFlipped: Bool { true }
    init(model: ViewerModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    var canal: NerveCanal? { model.reviewedCanal }
    func refresh() {
        if lastCanal != canal || lastVolume !== model.volume || lastField != model.reviewField || lastDistance != model.reviewDistance || lastCenter != model.center || lastWindow != model.window || lastLongitudinal != model.reviewLongitudinal {
            if let frame = canal?.path.frame(at: model.reviewDistance) {
                image = model.volume?.canalSection(frame: frame,field: model.reviewField,longitudinal: model.reviewLongitudinal,center: model.center,window: model.window)
            } else { image = nil }
            lastCanal = canal; lastVolume = model.volume; lastField = model.reviewField; lastDistance = model.reviewDistance
            lastCenter = model.center; lastWindow = model.window; lastLongitudinal = model.reviewLongitudinal
        }
        needsDisplay = true
    }
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite: 0.025,alpha: 1).setFill(); bounds.fill()
        let attrs: [NSAttributedString.Key:Any] = [.font: NSFont.systemFont(ofSize: 10),.foregroundColor: NSColor.lightGray]
        guard let image, let canal, let frame = canal.path.frame(at: model.reviewDistance) else {
            ("Seleccioná un canal con al menos dos puntos distintos." as NSString).draw(at: CGPoint(x: 20,y: 25),withAttributes: attrs); return
        }
        let side = max(1,min(bounds.width-50,bounds.height-60)), r = CGRect(x: (bounds.width-side)/2,y: (bounds.height-side)/2,width: side,height: side)
        NSImage(cgImage: image,size: r.size).draw(in: r,from: .zero,operation: .copy,fraction: 1,respectFlipped: true,hints: [.interpolation:NSImageInterpolation.high])
        let h = model.reviewLongitudinal ? frame.tangent : frame.horizontal, v = frame.vertical
        let normal = simd_normalize(simd_cross(h,v)), scale = r.width/model.reviewField
        func project(_ p: SIMD3<Double>) -> CGPoint { let d = p-frame.center; return CGPoint(x: r.midX+simd_dot(d,h)*scale,y: r.midY-simd_dot(d,v)*scale) }
        if (model.reviewSourceIndex == nil ? model.showPlanning : model.showXelisCanals), canal.visible {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r).addClip()
            let rgb = canal.color.rgb, color = NSColor(calibratedRed: rgb.x,green: rgb.y,blue: rgb.z,alpha: 0.55)
            let path = canal.path
            for (a,b) in zip(path.points,path.points.dropFirst()) {
                let start = simd_dot(a-frame.center,normal), delta = simd_dot(b-a,normal), radius = canal.diameter/2
                var lo = 0.0, hi = 1.0
                if abs(delta) < 1e-10 { if abs(start) > radius { continue } }
                else { let t0 = (-radius-start)/delta, t1 = (radius-start)/delta; lo = max(0,min(t0,t1)); hi = min(1,max(t0,t1)); if lo > hi { continue } }
                let p = project(a+(b-a)*lo), q = project(a+(b-a)*hi), thickness = max(2,canal.diameter*scale)
                color.setStroke(); color.setFill()
                if hypot(p.x-q.x,p.y-q.y) < 0.1 { NSBezierPath(ovalIn: CGRect(x: p.x-thickness/2,y: p.y-thickness/2,width: thickness,height: thickness)).fill() }
                else { let line = NSBezierPath(); line.move(to: p); line.line(to: q); line.lineCapStyle = .round; line.lineWidth = thickness; line.stroke() }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let cross = NSBezierPath(); cross.lineWidth = 1
        cross.move(to: CGPoint(x: r.midX-6,y: r.midY)); cross.line(to: CGPoint(x: r.midX+6,y: r.midY))
        cross.move(to: CGPoint(x: r.midX,y: r.midY-6)); cross.line(to: CGPoint(x: r.midX,y: r.midY+6))
        NSColor.white.setStroke(); cross.stroke()
        func label(_ direction: SIMD3<Double>) -> String {
            let axis = (0..<3).max { abs(direction[$0]) < abs(direction[$1]) }!
            return direction[axis] > 0 ? ["L","P","S"][axis] : ["R","A","I"][axis]
        }
        (label(v) as NSString).draw(at: CGPoint(x: r.midX-4,y: r.minY-17),withAttributes: attrs)
        (label(-v) as NSString).draw(at: CGPoint(x: r.midX-4,y: r.maxY+3),withAttributes: attrs)
        (label(-h) as NSString).draw(at: CGPoint(x: r.minX-16,y: r.midY),withAttributes: attrs)
        (label(h) as NSString).draw(at: CGPoint(x: r.maxX+5,y: r.midY),withAttributes: attrs)
        (String(format: "Centro L %.1f · P %.1f · S %.1f mm",frame.center.x,frame.center.y,frame.center.z) as NSString).draw(at: CGPoint(x: 12,y: 4),withAttributes: attrs)
        let ruler = NSBezierPath(); ruler.move(to: CGPoint(x: 15,y: bounds.height-18)); ruler.line(to: CGPoint(x: 15+5*scale,y: bounds.height-18)); NSColor.gray.setStroke(); ruler.stroke()
        ("5 mm · reformateo interpolado" as NSString).draw(at: CGPoint(x: 15,y: bounds.height-14),withAttributes: attrs)
    }
}
