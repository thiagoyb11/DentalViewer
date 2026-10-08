import AppKit
import simd

struct SavedCanalVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}
enum XelisOverlayGeometry {
    static func clipped(_ a: SIMD3<Double>, _ b: SIMD3<Double>, center: SIMD3<Double>, normal: SIMD3<Double>, halfWidth: Double) -> (SIMD3<Double>,SIMD3<Double>)? {
        let start = simd_dot(a-center,normal), delta = simd_dot(b-a,normal)
        var lo = 0.0, hi = 1.0
        if abs(delta) < 1e-10 { if abs(start) > halfWidth { return nil } }
        else { let x = (-halfWidth-start)/delta, y = (halfWidth-start)/delta; lo = max(0,min(x,y)); hi = min(1,max(x,y)); if lo > hi { return nil } }
        return (a+(b-a)*lo,a+(b-a)*hi)
    }
    static func vertices(project: XelisProject,volume: CTVolume) -> [SavedCanalVertex] {
        let physical = SIMD3(Double(volume.width),Double(volume.height),Double(volume.depth))*volume.spacing
        let scale = max(physical.x,physical.y,physical.z)
        let center = volume.origin+SIMD3(Double(volume.width-1),Double(volume.height-1),Double(volume.depth-1))*volume.spacing/2
        let sides = 8
        var vertices: [SavedCanalVertex] = []
        for canal in project.canals {
            var rings: [[SavedCanalVertex]] = []
            for i in canal.points.indices {
                let v = canal.verticals[i], n = simd_normalize(simd_cross(v,canal.tangents[i]))
                rings.append((0..<sides).map { side in
                    let angle = 2*Double.pi*Double(side)/Double(sides), normal = v*cos(angle)+n*sin(angle)
                    return SavedCanalVertex(position: SIMD4(SIMD3<Float>((canal.points[i]+normal*XelisProject.displayRadius-center)/scale),1),normal: SIMD4(SIMD3<Float>(normal),0))
                })
            }
            for i in 1..<rings.count { for j in 0..<sides {
                let k = (j+1)%sides
                vertices.append(contentsOf: [rings[i-1][j],rings[i][j],rings[i][k],rings[i-1][j],rings[i][k],rings[i-1][k]])
            } }
        }
        return vertices
    }
}
extension DentalImagesView {
    func drawXelisCanals(in rect: CGRect, cell: Int) {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return }
        guard model.showXelisCanals, let project = model.xelisProject, let volume = renderedVolume, let curve = renderedCurve else { return }
        NSColor.systemGreen.setStroke()
        func screen(_ column: Double, _ height: Double) -> CGPoint {
            let row = Double(volume.depth-1)-height/volume.spacing.z
            return CGPoint(x: rect.minX+column*rect.width,y: rect.minY+(row+0.5)/Double(volume.depth)*rect.height)
        }
        if panoramic {
            for canal in project.canals {
                let path = NSBezierPath(); path.lineWidth = 1.5
                for (i,point) in canal.points.enumerated() {
                    let local = point-volume.origin
                    let index = curve.samples.indices.min { a,b in
                        func distance(_ index: Int) -> Double {
                            let sample = curve.samples[index]
                            let origin = sample.sourcePosition ?? SIMD3(sample.position.x,sample.position.y,local.z)
                            let vertical = sample.sourceVertical ?? SIMD3(0,0,1)
                            let d = local-origin
                            return simd_length_squared(d-vertical*simd_dot(d,vertical))
                        }
                        return distance(a) < distance(b)
                    }!
                    let p = screen((Double(index)+0.5)/Double(curve.samples.count),curve.imageHeight(point: local,sample: curve.samples[index]))
                    if i == 0 { path.move(to: p) } else { path.line(to: p) }
                }
                path.stroke()
            }
        } else if indices.indices.contains(cell) {
            let sample = curve.samples[indices[cell]]
            let origin = sample.sourcePosition ?? SIMD3(sample.position.x,sample.position.y,0)
            let vertical = sample.sourceVertical ?? SIMD3(0,0,1)
            let normal = sample.sourceNormal ?? SIMD3(sample.normal.x,sample.normal.y,0)
            let tangent = simd_normalize(simd_cross(normal,vertical))
            func screenPoint(_ point: SIMD3<Double>) -> CGPoint {
                let local = point-volume.origin
                return screen(0.5+simd_dot(local-origin,normal)/renderedField,curve.imageHeight(point: local,sample: sample))
            }
            for canal in project.canals {
                for (a,b) in zip(canal.points,canal.points.dropFirst()) {
                    guard let (a,b) = XelisOverlayGeometry.clipped(a,b,center: volume.origin+origin,normal: tangent,halfWidth: XelisProject.displayRadius) else { continue }
                    let path = NSBezierPath(); path.move(to: screenPoint(a)); path.line(to: screenPoint(b)); path.lineWidth = max(1.5,XelisProject.displayRadius*2*rect.width/renderedField); path.lineCapStyle = .round; path.stroke()
                }
            }
        }
    }
}
