import Foundation
import CoreGraphics
import simd

struct ArchSample {
    let position: SIMD2<Double> // Patient x/y, relative to volume origin, in mm.
    let normal: SIMD2<Double>
    var sourcePosition: SIMD3<Double>? = nil
    var sourceVertical: SIMD3<Double>? = nil
    var sourceNormal: SIMD3<Double>? = nil
}
struct ArchCurve {
    var samples: [ArchSample]
    var step: Double
    var distances: [Double]
    var referenceHeight: Double? = nil
    var length: Double { distances.last ?? 0 }
    // Image edges lie half a column beyond the endpoint centres, like CT voxel edges.
    var imageWidth: Double { length*Double(samples.count)/Double(samples.count-1) }
    func index(at distance: Double) -> Int {
        var lo = 0, hi = distances.count-1
        while lo < hi { let mid = (lo+hi)/2; if distances[mid] < distance { lo = mid+1 } else { hi = mid } }
        return lo > 0 && abs(distances[lo-1]-distance) < abs(distances[lo]-distance) ? lo-1 : lo
    }
    func distance(atColumn column: Double) -> Double {
        let column = min(Double(samples.count-1),max(0,column))
        let a = Int(column), b = min(samples.count-1,a+1)
        return distances[a]+(distances[b]-distances[a])*(column-Double(a))
    }
    func column(atDistance distance: Double) -> Double {
        let distance = min(length,max(0,distance))
        var lo = 0, hi = distances.count-1
        while lo < hi { let mid = (lo+hi)/2; if distances[mid] < distance { lo = mid+1 } else { hi = mid } }
        if lo == 0 { return 0 }
        return Double(lo-1)+(distance-distances[lo-1])/max(1e-12,distances[lo]-distances[lo-1])
    }
    init(saved: XelisCurve, origin: SIMD3<Double>) {
        samples = saved.points.indices.map { i in
            let p = saved.points[i]-origin, n = simd_cross(saved.verticals[i],saved.tangents[i])
            return ArchSample(position: SIMD2(p.x,p.y),normal: simd_normalize(SIMD2(n.x,n.y)),sourcePosition: p,sourceVertical: saved.verticals[i],sourceNormal: n)
        }
        var d = [0.0]
        for i in 1..<saved.points.count { d.append(d.last!+simd_distance(saved.points[i-1],saved.points[i])) }
        distances = d; step = d.last!/Double(samples.count-1)
        referenceHeight = samples[0].sourcePosition!.z
    }
    /// A display surface parallel to the saved arch. Never changes the source geometry.
    func displaced(by offset: Double) -> ArchCurve {
        guard offset != 0 else { return self }
        var result = self
        result.samples = samples.map { sample in
            var position = sample.position+sample.normal*offset
            var sourcePosition = sample.sourcePosition
            if let p = sample.sourcePosition, let normal = sample.sourceNormal {
                let q = p+normal*offset
                sourcePosition = q; position = SIMD2(q.x,q.y)
            }
            return ArchSample(position: position,normal: sample.normal,sourcePosition: sourcePosition,
                              sourceVertical: sample.sourceVertical,sourceNormal: sample.sourceNormal)
        }
        result.distances = [0]
        for i in 1..<samples.count {
            let a = result.samples[i-1], b = result.samples[i]
            let distance: Double
            if let p = a.sourcePosition, let q = b.sourcePosition { distance = simd_distance(p,q) }
            else { distance = simd_distance(a.position,b.position) }
            result.distances.append(result.distances.last!+distance)
        }
        result.step = result.length/Double(samples.count-1)
        return result
    }
    // Shared map for image sampling and saved canal overlays. Stored tilted axes are retained.
    func localPosition(sample: ArchSample, height: Double, offset: Double) -> SIMD3<Double> {
        if let p = sample.sourcePosition, let vertical = sample.sourceVertical, let normal = sample.sourceNormal {
            return p+vertical*(height-referenceHeight!)+normal*offset
        }
        let xy = sample.position+sample.normal*offset
        return SIMD3(xy.x,xy.y,height)
    }
    func imageHeight(point: SIMD3<Double>, sample: ArchSample) -> Double {
        if let p = sample.sourcePosition, let vertical = sample.sourceVertical {
            return simd_dot(point-p,vertical)+referenceHeight!
        }
        return point.z
    }

    init(points: [CGPoint], spacing: SIMD2<Double>, requestedStep: Double = 0.25) throws {
        guard points.count >= 2, spacing.x > 0, spacing.y > 0, requestedStep > 0 else { throw ViewerError.message("Marcá al menos dos puntos para definir la curva dental.") }
        let points = points.map { SIMD2<Double>($0.x * spacing.x, $0.y * spacing.y) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), zip(points, points.dropFirst()).allSatisfy({ simd_distance($0, $1) > 0.001 }) else {
            throw ViewerError.message("La curva tiene puntos inválidos o repetidos.")
        }
        var path: [SIMD2<Double>] = [points[0]]
        if points.count == 2 { path.append(points[1]) }
        else {
            for i in 0..<points.count - 1 {
                let p1 = points[i], p2 = points[i + 1]
                let p0 = i == 0 ? 2 * p1 - p2 : points[i - 1]
                let p3 = i + 2 < points.count ? points[i + 2] : 2 * p2 - p1
                let count = min(4096, max(8, Int(ceil(simd_distance(p1, p2) / 0.1))))
                for j in 1...count {
                    let t = Double(j) / Double(count), t2 = t * t, t3 = t2 * t
                    path.append(0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
                }
            }
        }
        var distances = [0.0]
        for i in 1..<path.count { distances.append(distances.last! + simd_distance(path[i - 1], path[i])) }
        let length = distances.last!
        guard length >= requestedStep, length < 2000 else { throw ViewerError.message("La curva es demasiado corta o larga.") }
        let count = min(2048, max(2, Int(ceil(length / requestedStep)) + 1)), step = length / Double(count - 1)
        var resampled: [SIMD2<Double>] = [], segment = 1
        for i in 0..<count {
            let distance = Double(i) * step
            while segment < path.count - 1 && distances[segment] < distance { segment += 1 }
            let fraction = (distance - distances[segment - 1]) / max(1e-12, distances[segment] - distances[segment - 1])
            resampled.append(path[segment - 1] + (path[segment] - path[segment - 1]) * fraction)
        }
        samples = resampled.enumerated().map { i, point in
            let tangent = simd_normalize(resampled[min(count - 1, i + 1)] - resampled[max(0, i - 1)])
            return ArchSample(position: point, normal: SIMD2(-tangent.y, tangent.x))
        }
        self.step = step
        self.distances = (0..<count).map { Double($0)*step }
    }
}

extension CTVolume {
    /// Bilinear sampling with an explicit outside-volume value. Never extends edge anatomy.
    func dentalValue(at point: SIMD2<Double>, z: Int) -> Float? {
        let x = point.x / spacing.x, y = point.y / spacing.y
        guard x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1), z >= 0, z < depth else { return nil }
        return interpolated(x: x, y: y, z: z)
    }
    func displayByte(_ value: Float?, center: Double, window: Double) -> UInt8 {
        guard let value else { return 0 }
        let c = Float(center - 0.5), w = Float(max(1, window) - 1)
        let normalized = w == 0 ? (value > c ? Float(1) : 0) : min(1, max(0, (value - c) / w + 0.5))
        return UInt8((monochrome1 ? 1 - normalized : normalized) * 255)
    }
    func panoramic(curve: ArchCurve, thickness: Double, maximum: Bool, center: Double, window: Double, shouldCancel: () -> Bool = { false }) -> CGImage? {
        let width = curve.samples.count
        let thickness = max(0, thickness), sampleStep = min(spacing.x, spacing.y)
        let count = thickness < sampleStep ? 1 : min(257, Int(ceil(thickness / sampleStep)) + 1)
        var bytes = [UInt8](repeating: 0, count: width * depth)
        for y in 0..<depth {
            if shouldCancel() { return nil }
            let z = depth - 1 - y
            for (x, sample) in curve.samples.enumerated() {
                var value: Float = maximum ? -.greatestFiniteMagnitude : 0
                var valid = 0
                for s in 0..<count {
                    let offset = count == 1 ? 0 : thickness * (Double(s) / Double(count - 1) - 0.5)
                    if let density = patientValue(at: origin+curve.localPosition(sample: sample,height: Double(z)*spacing.z,offset: offset)) {
                        value = maximum ? max(value, density) : value + density; valid += 1
                    }
                }
                bytes[y * width + x] = displayByte(valid == 0 ? nil : (maximum ? value : value / Float(valid)), center: center, window: window)
            }
        }
        return Self.grayImage(bytes: bytes, width: width, height: depth)
    }
    func transverse(curve: ArchCurve, index: Int, field: Double = 40, center: Double, window: Double) -> CGImage? {
        let step = min(spacing.x, spacing.y), width = max(2, Int(ceil(field / step)) + 1)
        let sample = curve.samples[min(curve.samples.count - 1, max(0, index))]
        var bytes = [UInt8](repeating: 0, count: width * depth)
        for y in 0..<depth {
            for x in 0..<width {
                let offset = field * (Double(x) / Double(width - 1) - 0.5)
                bytes[y * width + x] = displayByte(patientValue(at: origin+curve.localPosition(sample: sample,height: Double(depth-1-y)*spacing.z,offset: offset)), center: center, window: window)
            }
        }
        return Self.grayImage(bytes: bytes, width: width, height: depth)
    }
}
