import AppKit
import simd

enum ImplantOverlay {
    static func draw(_ contours: [[SIMD3<Double>]], color: NSColor, project: (SIMD3<Double>) -> CGPoint?) {
        let path = NSBezierPath(); path.windingRule = .evenOdd
        for contour in contours where contour.count >= 3 {
            let points = contour.compactMap(project)
            guard points.count == contour.count, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }; path.close()
        }
        color.withAlphaComponent(0.28).setFill(); path.fill()
        color.setStroke(); path.lineWidth = 1.25; path.lineJoinStyle = .round; path.stroke()
    }
}
