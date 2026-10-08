import Foundation
import simd

struct CanalFrame {
    var center: SIMD3<Double>, tangent: SIMD3<Double>, horizontal: SIMD3<Double>, vertical: SIMD3<Double>
}
struct CanalPath {
    let points: [SIMD3<Double>]
    let distances: [Double]
    let subdivisions: Int
    var length: Double { distances.last ?? 0 }
    init(points controls: [PatientPoint], smooth: Bool) {
        subdivisions = smooth ? 4 : 1
        let p = controls.map(\.vector)
        var samples: [SIMD3<Double>] = []
        if let first = p.first { samples.append(first) }
        // Coordinate-wise monotone Hermite interpolation: every control point is retained,
        // and samples cannot overshoot the bounding box of their adjacent control points.
        func slope(_ i: Int, _ axis: Int) -> Double {
            if i == 0 { return p[1][axis]-p[0][axis] }
            if i == p.count-1 { return p[i][axis]-p[i-1][axis] }
            let a = p[i][axis]-p[i-1][axis], b = p[i+1][axis]-p[i][axis]
            return a*b > 0 ? 2*a*b/(a+b) : 0
        }
        if p.count > 1 {
            for i in 0..<p.count-1 {
                for j in 1...subdivisions {
                    let t = Double(j)/Double(subdivisions), t2 = t*t, t3 = t2*t
                    var q = p[i]*(1-t)+p[i+1]*t
                    if smooth {
                        for axis in 0..<3 {
                            let a = p[i][axis], b = p[i+1][axis], d = b-a
                            var m0 = slope(i,axis), m1 = slope(i+1,axis)
                            if abs(d) < 1e-12 { m0 = 0; m1 = 0 }
                            else {
                                let norm = hypot(m0/d,m1/d)
                                if norm > 3 { m0 *= 3/norm; m1 *= 3/norm }
                            }
                            q[axis] = min(max(a,b),max(min(a,b),(2*t3-3*t2+1)*a+(t3-2*t2+t)*m0+(-2*t3+3*t2)*b+(t3-t2)*m1))
                        }
                    }
                    samples.append(q)
                }
            }
        }
        points = samples
        var cumulative = [Double]()
        for (i,p) in samples.enumerated() { cumulative.append(i == 0 ? 0 : cumulative.last! + simd_distance(samples[i-1],p)) }
        distances = cumulative
    }
    func frame(at distance: Double) -> CanalFrame? {
        guard points.count >= 2, length > 0.001 else { return nil }
        let d = min(length,max(0,distance))
        var i = 1
        while i < points.count-1 && distances[i] < d { i += 1 }
        while i < points.count-1 && distances[i]-distances[i-1] < 1e-10 { i += 1 }
        if distances[i]-distances[i-1] < 1e-10 {
            while i > 1 && distances[i]-distances[i-1] < 1e-10 { i -= 1 }
        }
        let delta = points[i]-points[i-1], segmentLength = simd_length(delta)
        guard segmentLength > 1e-10 else { return nil }
        let tangent = delta/segmentLength
        let center = points[i-1]+delta*min(1,max(0,(d-distances[i-1])/segmentLength))
        let up = abs(tangent.z) < 0.95 ? SIMD3<Double>(0,0,1) : SIMD3<Double>(0,1,0)
        let vertical = simd_normalize(up-tangent*simd_dot(up,tangent))
        return CanalFrame(center: center,tangent: tangent,horizontal: simd_normalize(simd_cross(vertical,tangent)),vertical: vertical)
    }
}

struct CanalHistory {
    private(set) var past: [[NerveCanal]] = []
    private(set) var future: [[NerveCanal]] = []
    mutating func record(_ canals: [NerveCanal]) {
        if past.last != canals { past.append(canals); if past.count > 100 { past.removeFirst() } }
        future = []
    }
    mutating func undo(_ current: [NerveCanal]) -> [NerveCanal]? {
        guard let previous = past.popLast() else { return nil }; future.append(current); return previous
    }
    mutating func redo(_ current: [NerveCanal]) -> [NerveCanal]? {
        guard let next = future.popLast() else { return nil }; past.append(current); return next
    }
}
