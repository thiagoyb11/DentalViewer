import Foundation
import simd

struct PatientPoint: Codable, Equatable {
    var x: Double, y: Double, z: Double
    init(_ vector: SIMD3<Double>) { x = vector.x; y = vector.y; z = vector.z }
    var vector: SIMD3<Double> { SIMD3(x, y, z) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && max(abs(x),abs(y),abs(z)) < 1_000_000 }
}
struct PlannedImplant: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Implante genérico"
    var entry: PatientPoint
    var diameter = 4.0
    var length = 10.0
    var lateralAngle = 0.0
    var anteriorAngle = 0.0
    var axis: SIMD3<Double> {
        simd_normalize(SIMD3(tan(lateralAngle * .pi / 180), tan(anteriorAngle * .pi / 180), -1))
    }
    var apex: SIMD3<Double> { entry.vector + axis * length }
}
enum ImplantDimensions {
    static let diameters = [3.5,4.0]
    static let lengths = [8.0,10.0,11.5,13.0,15.0]
    static let diameterRange = 1.0...15.0
    static let lengthRange = 1.0...50.0
}
enum CanalSide: String, Codable, CaseIterable { case unspecified = "Sin asignar", right = "Derecho", left = "Izquierdo" }
enum CanalColor: String, Codable, CaseIterable {
    case orange = "Naranja", yellow = "Amarillo", cyan = "Celeste", pink = "Rosa", green = "Verde"
    var rgb: SIMD3<Double> {
        switch self { case .orange: return SIMD3(1,0.55,0.15); case .yellow: return SIMD3(1,0.85,0.2); case .cyan: return SIMD3(0.2,0.8,1); case .pink: return SIMD3(1,0.4,0.7); case .green: return SIMD3(0.35,0.9,0.4) }
    }
}
enum CanalInteraction: String, CaseIterable { case draw = "Trazar", edit = "Editar", insert = "Insertar" }
struct NerveCanal: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var diameter = 2.0
    var points: [PatientPoint] = []
    var side: CanalSide = .unspecified
    var color: CanalColor = .orange
    var visible = true
    var smooth = false
    enum CodingKeys: String, CodingKey { case id, name, diameter, points, side, color, visible, smooth }
    init(id: UUID = UUID(), name: String, diameter: Double = 2, points: [PatientPoint] = [], side: CanalSide = .unspecified, color: CanalColor = .orange, visible: Bool = true, smooth: Bool = false) {
        self.id = id; self.name = name; self.diameter = diameter; self.points = points
        self.side = side; self.color = color; self.visible = visible; self.smooth = smooth
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self,forKey: .id); name = try c.decode(String.self,forKey: .name)
        diameter = try c.decode(Double.self,forKey: .diameter); points = try c.decode([PatientPoint].self,forKey: .points)
        side = try c.decodeIfPresent(CanalSide.self,forKey: .side) ?? .unspecified
        color = try c.decodeIfPresent(CanalColor.self,forKey: .color) ?? .orange
        visible = try c.decodeIfPresent(Bool.self,forKey: .visible) ?? true
        smooth = try c.decodeIfPresent(Bool.self,forKey: .smooth) ?? false
    }
    var path: CanalPath { CanalPath(points: points, smooth: smooth) }
    var primitiveCount: Int { points.isEmpty ? 0 : max(1,(points.count-1) * (smooth ? 4 : 1)) }
}
struct PlanningData: Codable, Equatable {
    var implants: [PlannedImplant] = []
    var canals: [NerveCanal] = []
    var primitiveCount: Int { implants.count + canals.reduce(0) { $0 + $1.primitiveCount } }
}
struct PlanningDocument: Codable {
    var version = 2
    var studyUID: String
    var seriesUID: String
    var dimensions: [Int]
    var spacing: PatientPoint
    var origin: PatientPoint
    var planning: PlanningData
    init(volume: CTVolume, planning: PlanningData) {
        studyUID = volume.studyUID; seriesUID = volume.seriesUID
        dimensions = [volume.width, volume.height, volume.depth]
        spacing = PatientPoint(volume.spacing); origin = PatientPoint(volume.origin)
        self.planning = planning
    }
    func validate(for volume: CTVolume) throws {
        guard (1...2).contains(version), studyUID == volume.studyUID, seriesUID == volume.seriesUID,
              dimensions == [volume.width, volume.height, volume.depth], spacing.isFinite, origin.isFinite,
              simd_distance(spacing.vector, volume.spacing) < 0.00001,
              simd_distance(origin.vector, volume.origin) < 0.00001 else {
            throw ViewerError.message("La planificación pertenece a otra serie o tiene una geometría diferente. Abrí el estudio original correspondiente.")
        }
        guard planning.implants.count <= 100, planning.canals.count <= 10, planning.primitiveCount <= 256,
              Set(planning.implants.map(\.id)).count == planning.implants.count,
              Set(planning.canals.map(\.id)).count == planning.canals.count,
              planning.implants.allSatisfy({ $0.entry.isFinite && $0.diameter.isFinite && $0.diameter >= 1 && $0.diameter <= 15 && $0.length.isFinite && $0.length >= 1 && $0.length <= 50 && $0.lateralAngle.isFinite && abs($0.lateralAngle) <= 85 && $0.anteriorAngle.isFinite && abs($0.anteriorAngle) <= 85 }),
              planning.canals.allSatisfy({ $0.name.count <= 100 && $0.points.count <= 1000 && $0.points.allSatisfy(\.isFinite) && $0.diameter.isFinite && $0.diameter >= 0.1 && $0.diameter <= 10 }) else {
            throw ViewerError.message("La planificación contiene medidas, puntos o identificadores inválidos.")
        }
    }
}

enum PlanningGeometry {
    struct ClosestPair { var implant: SIMD3<Double>, canal: SIMD3<Double>; var distance: Double { simd_distance(implant,canal) } }
    struct CanalProximity { var canalID: UUID, canalName: String, distanceAlong: Double, gap: Double, pair: ClosestPair }
    /// Closest distance between two finite line segments, including degenerate points.
    static func closestPair(_ p1: SIMD3<Double>, _ q1: SIMD3<Double>, _ p2: SIMD3<Double>, _ q2: SIMD3<Double>) -> ClosestPair {
        let u = q1 - p1, v = q2 - p2, w = p1 - p2
        let a = simd_dot(u,u), b = simd_dot(u,v), c = simd_dot(v,v), d = simd_dot(u,w), e = simd_dot(v,w)
        let epsilon = 1e-12
        if a < epsilon && c < epsilon { return ClosestPair(implant: p1,canal: p2) }
        if a < epsilon { return ClosestPair(implant: p1,canal: p2 + v * min(1,max(0,e/c))) }
        if c < epsilon { return ClosestPair(implant: p1 + u * min(1,max(0,-d/a)),canal: p2) }
        let denominator = a * c - b * b
        var s = denominator > epsilon ? min(1,max(0,(b * e - c * d) / denominator)) : 0
        var t = (b * s + e) / c
        if t < 0 { t = 0; s = min(1,max(0,-d/a)) }
        else if t > 1 { t = 1; s = min(1,max(0,(b-d)/a)) }
        return ClosestPair(implant: p1+s*u,canal: p2+t*v)
    }
    static func segmentDistance(_ p1: SIMD3<Double>, _ q1: SIMD3<Double>, _ p2: SIMD3<Double>, _ q2: SIMD3<Double>) -> Double {
        closestPair(p1,q1,p2,q2).distance
    }
    static func separation(implant: PlannedImplant, canals: [NerveCanal]) -> Double? {
        proximity(implant: implant,canals: canals)?.gap
    }
    static func proximity(implant: PlannedImplant, canals: [NerveCanal]) -> CanalProximity? {
        var result: CanalProximity?
        for canal in canals {
            let path = canal.path
            for i in 0..<max(0,path.points.count-1) {
                let a = path.points[i], b = path.points[i+1]
                // Conservative capsule envelope around the threaded body; this is not a mesh-surface clearance.
                let pair = closestPair(implant.entry.vector, implant.apex, a,b)
                let gap = pair.distance - implant.diameter / 2 - canal.diameter / 2
                if result == nil || gap < result!.gap {
                    result = CanalProximity(canalID: canal.id,canalName: canal.name,distanceAlong: path.distances[i]+simd_distance(a,pair.canal),gap: gap,pair: pair)
                }
            }
        }
        return result
    }
}
