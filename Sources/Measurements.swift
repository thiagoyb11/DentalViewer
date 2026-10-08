import AppKit

struct PanoramicMeasurement: Identifiable {
    let id = UUID()
    let start: CGPoint, end: CGPoint // Column and row in the reconstructed image, independent of window size.
    let mm: Double
}

struct TransverseMeasurement: Identifiable {
    let id = UUID()
    let section: Int
    let start: CGPoint, end: CGPoint // Offset along the normal and image height, both in mm.
    let mm: Double
}

enum PanoramicMeasurementGeometry {
    static func imagePoint(_ point: CGPoint, in rect: CGRect, columns: Int, rows: Int) -> CGPoint {
        CGPoint(x: min(Double(columns-1),max(0,(point.x-rect.minX)/rect.width*Double(columns)-0.5)),
                y: min(Double(rows-1),max(0,(point.y-rect.minY)/rect.height*Double(rows)-0.5)))
    }
    static func screenPoint(_ point: CGPoint, in rect: CGRect, columns: Int, rows: Int) -> CGPoint {
        CGPoint(x: rect.minX+(point.x+0.5)/Double(columns)*rect.width,
                y: rect.minY+(point.y+0.5)/Double(rows)*rect.height)
    }
    /// Distance on the developed panoramic image: horizontal arc length and vertical millimetres.
    /// It is not the straight 3D distance between the corresponding patient positions.
    static func distance(_ a: CGPoint, _ b: CGPoint, curve: ArchCurve, verticalSpacing: Double) -> Double {
        hypot(curve.distance(atColumn: b.x)-curve.distance(atColumn: a.x),(b.y-a.y)*verticalSpacing)
    }
}

enum MeasurementOverlay {
    static func draw(from a: CGPoint, to b: CGPoint, mm: Double, bounds: CGRect) {
        let path = NSBezierPath(); path.move(to: a); path.line(to: b); path.lineWidth = 1.5
        NSColor.systemYellow.setStroke(); path.stroke(); NSColor.systemYellow.setFill()
        for p in [a,b] { NSBezierPath(ovalIn: CGRect(x: p.x-3,y: p.y-3,width: 6,height: 6)).fill() }
        let text = String(format: "%.2f mm",mm) as NSString
        let attributes: [NSAttributedString.Key:Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12,weight: .semibold),.foregroundColor: NSColor.systemYellow,.backgroundColor: NSColor.black.withAlphaComponent(0.7)]
        let size = text.size(withAttributes: attributes)
        let label = CGPoint(x: max(bounds.minX,min(bounds.maxX-size.width,(a.x+b.x)/2+5)),
                            y: max(bounds.minY,min(bounds.maxY-size.height,(a.y+b.y)/2-18)))
        text.draw(at: label,withAttributes: attributes)
    }
}
