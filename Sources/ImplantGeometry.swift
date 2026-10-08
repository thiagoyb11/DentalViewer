import Foundation
import simd

/// Generic implant body in millimetres: +Z runs from entry to apex.
/// Diameter is the outer thread envelope; length includes neck and rounded tip.
/// The profile is illustrative, not a manufacturer-specific implant library.
enum ImplantGeometry {
    struct Mesh {
        var points: [SIMD3<Double>]
        var normals: [SIMD3<Double>]
        var triangles: [Int]
        var rings: [[Int]]
    }
    private final class CachedMesh: NSObject {
        let mesh: Mesh
        init(_ mesh: Mesh) { self.mesh = mesh }
    }
    private static let cache: NSCache<NSString,CachedMesh> = {
        let cache = NSCache<NSString,CachedMesh>()
        cache.countLimit = 32; cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    struct Frame {
        let entry: SIMD3<Double>, axis: SIMD3<Double>, x: SIMD3<Double>, y: SIMD3<Double>
        init(_ implant: PlannedImplant) {
            entry = implant.entry.vector; axis = implant.axis
            let reference = abs(axis.z) > 0.9 ? SIMD3<Double>(0,1,0) : SIMD3<Double>(0,0,1)
            x = simd_normalize(simd_cross(reference,axis)); y = simd_cross(axis,x)
        }
        func point(_ p: SIMD3<Double>) -> SIMD3<Double> { entry+x*p.x+y*p.y+axis*p.z }
        func direction(_ p: SIMD3<Double>) -> SIMD3<Double> { x*p.x+y*p.y+axis*p.z }
        func local(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = p-entry
            return SIMD3(simd_dot(d,x),simd_dot(d,y),simd_dot(d,axis))
        }
    }
    static func mesh(diameter: Double, length: Double) -> Mesh {
        guard diameter.isFinite, length.isFinite, (1...15).contains(diameter), (1...50).contains(length) else {
            return Mesh(points: [],normals: [],triangles: [],rings: [])
        }
        let key = "\(diameter):\(length)" as NSString
        if let cached = cache.object(forKey: key) { return cached.mesh }
        let radius = diameter/2, pitch = min(1.1,length*0.14), neckPitch = min(0.25,length*0.035)
        func surfaceRadius(_ z: Double, _ angle: Double) -> Double {
            let t = min(1,max(0,z/length))
            if t < 0.08 { return radius*0.95 }
            if t >= 0.92 {
                let tip = (t-0.92)/0.08
                return radius*0.8*sqrt(max(0,1-pow(tip*0.85,2)))
            }
            let neck = t < 0.22, spacing = neck ? neckPitch : pitch
            let envelope = neck ? radius : radius*(1-0.2*(t-0.22)/0.70)
            let depth = neck ? min(diameter*0.035,spacing*0.10) : min(diameter*0.11,spacing*0.28)
            let phase = z/spacing-angle/(2*Double.pi)
            let fraction = phase-floor(phase), ridge = max(0,1-min(fraction,1-fraction)/0.28)
            // Fade thread depth at the collar and apical transitions.
            let fade = neck ? min(1,(t-0.08)/0.025) : min(1,(t-0.22)/0.025,(0.92-t)/0.025)
            return envelope-depth*(1-ridge)*max(0,fade)
        }
        let sides = 40
        var stations = [0.0]
        for (lo,hi,step) in [(0.0,0.08*length,length/30),(0.08*length,0.22*length,neckPitch/10),
                             (0.22*length,0.92*length,pitch/12),(0.92*length,length,length/150)] {
            let count = max(1,Int(ceil((hi-lo)/step)))
            stations += (1...count).map { lo+(hi-lo)*Double($0)/Double(count) }
        }
        var mesh = Mesh(points: [],normals: [],triangles: [],rings: [])
        for z in stations {
            var ring: [Int] = []
            for side in 0..<sides {
                let angle = 2*Double.pi*Double(side)/Double(sides), r = surfaceRadius(z,angle)
                let radial = SIMD3(cos(angle),sin(angle),0), tangent = SIMD3(-sin(angle),cos(angle),0)
                let epsilon = 0.0001
                let drAngle = (surfaceRadius(z,angle+epsilon)-surfaceRadius(z,angle-epsilon))/(2*epsilon)
                let lo = max(0,z-epsilon), hi = min(length,z+epsilon)
                let drZ = (surfaceRadius(hi,angle)-surfaceRadius(lo,angle))/(hi-lo)
                ring.append(mesh.points.count)
                mesh.points.append(radial*r+SIMD3(0,0,z))
                mesh.normals.append(simd_normalize(simd_cross(radial*drAngle+tangent*r,radial*drZ+SIMD3(0,0,1))))
            }
            mesh.rings.append(ring)
        }
        for row in 1..<mesh.rings.count { for side in 0..<sides {
            let next = (side+1)%sides
            let a = mesh.rings[row-1][side], b = mesh.rings[row-1][next]
            let c = mesh.rings[row][side], d = mesh.rings[row][next]
            mesh.triangles += [a,b,c,b,d,c]
        } }
        // Flat end faces close the body without extending beyond its configured length.
        for end in [0,mesh.rings.count-1] {
            let normal = SIMD3<Double>(0,0,end == 0 ? -1 : 1), z = stations[end]
            let center = mesh.points.count
            mesh.points.append(SIMD3(0,0,z)); mesh.normals.append(normal)
            let ring = mesh.rings[end].map { mesh.points[$0] }
            let start = mesh.points.count
            mesh.points += ring; mesh.normals += Array(repeating: normal,count: sides)
            for side in 0..<sides {
                let a = start+side, b = start+(side+1)%sides
                mesh.triangles += end == 0 ? [center,b,a] : [center,a,b]
            }
        }
        cache.setObject(CachedMesh(mesh),forKey: key,cost: mesh.points.count*48+mesh.triangles.count*8)
        return mesh
    }

    private struct PointKey: Hashable {
        var x: Int64, y: Int64, z: Int64
        init(_ p: SIMD3<Double>) {
            x = Int64((p.x*1e6).rounded()); y = Int64((p.y*1e6).rounded()); z = Int64((p.z*1e6).rounded())
        }
    }
    /// Actual intersection of the closed mesh with a physical slice plane.
    static func section(_ implant: PlannedImplant, center: SIMD3<Double>, normal: SIMD3<Double>) -> [[SIMD3<Double>]] {
        guard implant.entry.isFinite, center.x.isFinite, center.y.isFinite, center.z.isFinite,
              normal.x.isFinite, normal.y.isFinite, normal.z.isFinite, simd_length(normal) > 1e-8 else { return [] }
        let mesh = mesh(diameter: implant.diameter,length: implant.length), frame = Frame(implant)
        let n = SIMD3(simd_dot(normal,frame.x),simd_dot(normal,frame.y),simd_dot(normal,frame.axis))/simd_length(normal)
        let offset = simd_dot(frame.local(center),n), epsilon = 1e-8
        var points: [PointKey:SIMD3<Double>] = [:], neighbours: [PointKey:Set<PointKey>] = [:]
        for index in stride(from: 0,to: mesh.triangles.count,by: 3) {
            let triangle = (0..<3).map { mesh.points[mesh.triangles[index+$0]] }
            let distances = triangle.map { simd_dot($0,n)-offset }
            if distances.allSatisfy({ abs($0) <= epsilon }) { continue }
            var hits: [SIMD3<Double>] = []
            func add(_ p: SIMD3<Double>) { if !hits.contains(where: { simd_distance($0,p) < epsilon }) { hits.append(p) } }
            for edge in 0..<3 {
                let next = (edge+1)%3, a = distances[edge], b = distances[next]
                if abs(a) <= epsilon { add(triangle[edge]) }
                if (a < -epsilon && b > epsilon) || (a > epsilon && b < -epsilon) {
                    add(triangle[edge]+(triangle[next]-triangle[edge])*(a/(a-b)))
                }
            }
            guard hits.count == 2 else { continue }
            let a = PointKey(hits[0]), b = PointKey(hits[1]); if a == b { continue }
            points[a] = hits[0]; points[b] = hits[1]
            neighbours[a,default: []].insert(b); neighbours[b,default: []].insert(a)
        }
        var loops: [[SIMD3<Double>]] = []
        while let start = neighbours.first(where: { !$0.value.isEmpty })?.key {
            var current = start, keys = [start]
            while let next = neighbours[current]?.first {
                neighbours[current]?.remove(next); neighbours[next]?.remove(current)
                keys.append(next); current = next
                if current == start { break }
            }
            if current == start && keys.count >= 4 { loops.append(keys.compactMap { points[$0].map(frame.point) }) }
        }
        return loops
    }
    /// Side silhouette for the developed panorama, whose mapping is a projection.
    static func silhouette(_ implant: PlannedImplant, normal: SIMD3<Double>) -> [SIMD3<Double>] {
        let mesh = mesh(diameter: implant.diameter,length: implant.length), frame = Frame(implant)
        let cross = simd_cross(frame.axis,normal)
        let side = simd_length(cross) > 1e-8 ? simd_normalize(cross) : frame.x
        let localSide = SIMD3(simd_dot(side,frame.x),simd_dot(side,frame.y),0)
        var left: [SIMD3<Double>] = [], right: [SIMD3<Double>] = []
        for ring in mesh.rings {
            guard let lo = ring.min(by: { simd_dot(mesh.points[$0],localSide) < simd_dot(mesh.points[$1],localSide) }),
                  let hi = ring.max(by: { simd_dot(mesh.points[$0],localSide) < simd_dot(mesh.points[$1],localSide) }) else { continue }
            left.append(frame.point(mesh.points[lo])); right.append(frame.point(mesh.points[hi]))
        }
        return left+right.reversed()
    }
}
