import Foundation
import simd
import zlib

/// Coordinates copied from the saved Xelis snapshot, never derived from CT intensity.
struct XelisCurve {
    let points: [SIMD3<Double>]
    let verticals: [SIMD3<Double>]
    let tangents: [SIMD3<Double>]
    let controls: [SIMD3<Double>]
    let frames: [XelisFrame]
    let sourceRange: Range<Int>
}
struct XelisFrame {
    let distance: Double
    let point: SIMD3<Double>
    let vertical: SIMD3<Double>
    let tangent: SIMD3<Double>
}
final class XelisProject {
    let source: URL
    let arch: XelisCurve
    let canals: [XelisCurve]
    let reviewCanals: [NerveCanal]
    // Visual stroke width only; not a measurement or an inferred anatomical diameter.
    static let displayRadius = 0.65
    init(source: URL, arch: XelisCurve, canals: [XelisCurve]) {
        self.source = source; self.arch = arch; self.canals = canals
        reviewCanals = canals.enumerated().map { index,curve in
            NerveCanal(name: "Canal original \(index+1)",diameter: Self.displayRadius*2,points: curve.points.map(PatientPoint.init),color: .green,smooth: false)
        }
    }

    static func load(_ image: DICOMImage, volume: CTVolume) throws -> XelisProject {
        guard image.string(0x75730010) == "MEVISYS",
              image.string(0x75731000) == "MEVISYS_Lucion_PrivateTag_Identifier",
              image.string(0x75731001) == "Lucion 1.0.6.4 BN2(P)",
              image.string(0x0020000D) == volume.studyUID,
              let metadata = image.values[0x75731003], let archive = image.values[0x75731004],
              metadata.starts(with: Data("LucionSnapshotIdentifier_Version_30000001\0".utf8)) else {
            throw ViewerError.message("Proyecto Xelis de otra versión o estudio: no se importó su trazado.")
        }
        // Fixed header fields of snapshot metadata version 30000001, followed by MFC CStrings.
        var refs = XelisBinary(metadata, position: 1060)
        try refs.expect(1)
        let count = try refs.count(maximum: 10000)
        guard count == volume.depth, !volume.sourceSOPUIDs.contains("") else { throw ViewerError.message("El proyecto Xelis no referencia todos los cortes de esta serie.") }
        var sourceUIDs = Set<String>()
        for _ in 0..<count { guard sourceUIDs.insert(try refs.string()).inserted else { throw ViewerError.message("Referencias DICOM duplicadas en el proyecto Xelis.") } }
        guard sourceUIDs == volume.sourceSOPUIDs else { throw ViewerError.message("El trazado Xelis pertenece a otros cortes DICOM.") }
        let payload = try unzip(archive)
        let parsed = try decode(payload)
        let expected = SIMD3(Double(volume.width-1),Double(volume.height-1),Double(volume.depth-1))*volume.spacing
        guard simd_length(parsed.bounds-expected) < 0.001 else { throw ViewerError.message("La geometría guardada en Xelis no coincide con el volumen DICOM.") }
        func convert(_ curve: XelisCurve) throws -> XelisCurve {
            for p in curve.points + curve.controls + curve.frames.map(\.point) {
                guard (0..<3).allSatisfy({ p[$0] >= -0.001 && p[$0] <= expected[$0]+0.001 }) else { throw ViewerError.message("Coordenadas Xelis fuera del volumen; importación rechazada.") }
            }
            // This snapshot version stores local millimetres in the source axial LPS basis.
            return XelisCurve(points: curve.points.map { $0+volume.origin },verticals: curve.verticals,tangents: curve.tangents,
                              controls: curve.controls.map { $0+volume.origin },
                              frames: curve.frames.map { XelisFrame(distance: $0.distance,point: $0.point+volume.origin,vertical: $0.vertical,tangent: $0.tangent) },sourceRange: curve.sourceRange)
        }
        return try XelisProject(source: image.url,arch: convert(parsed.arch),canals: parsed.canals.map(convert))
    }

    static func decode(_ payload: Data) throws -> (bounds: SIMD3<Double>, arch: XelisCurve, canals: [XelisCurve]) {
        var root = XelisBinary(payload)
        try root.expect(0x30000017)
        var box = XelisBinary(payload,position: 768)
        try box.expect(0x10000001)
        var bounds = SIMD3<Double>.zero
        for axis in 0..<3 { guard try box.float() == 0 else { throw ViewerError.message("Origen local Xelis no compatible.") }; bounds[axis] = try box.float() }
        // Locate typed CCurveStrider2 records. Classification comes from the serialized
        // canal collection (count, IDs, version and object type), never point location.
        let marker = Data([2,0,0,0x10])
        var offset = 0, matches: [(XelisCurve,[XelisCurve])] = []
        while offset < payload.count, let range = payload.range(of: marker,in: offset..<payload.count) {
            offset = range.upperBound
            guard range.lowerBound >= 70 else { continue }
            do {
                var curveReader = XelisBinary(payload,position: range.lowerBound-70)
                try curveReader.generalCurveHeader()
                let arch = try curveReader.curve()
                try curveReader.expect(1); try curveReader.expect(0)
                let count = try curveReader.count(maximum: 10)
                guard count > 0 else { continue }
                var canals: [XelisCurve] = []
                for index in 0..<count {
                    try curveReader.expect(UInt32(index+1)) // Stored object ID.
                    try curveReader.expect(0x10000001); try curveReader.expect(2) // Nerve collection entry.
                    for _ in 0..<6 { _ = try curveReader.float() } // Stored presentation fields, not anatomy.
                    try curveReader.generalCurveHeader()
                    canals.append(try curveReader.curve())
                }
                matches.append((arch,canals))
            } catch { continue } // Other typed records include empty view curves and segmentation buffers.
        }
        guard matches.count == 1 else { throw ViewerError.message("No se encontró una única colección de canales Xelis compatible; no se estimará un trazado.") }
        return (bounds,matches[0].0,matches[0].1)
    }

    static func unzip(_ archive: Data) throws -> Data {
        var r = XelisBinary(archive)
        try r.expect(0x04034b50)
        _ = try r.word()
        let flags = try r.word(), method = try r.word()
        guard flags & 0x9 == 0, method == 8 else { throw ViewerError.message("Compresión del proyecto Xelis no compatible.") }
        _ = try r.word(); _ = try r.word()
        let checksum = try r.uint(), compressed = Int(try r.uint()), expanded = Int(try r.uint())
        let nameLength = Int(try r.word()), extraLength = Int(try r.word())
        guard nameLength == 1, try r.bytes(nameLength) == Data([45]), expanded > 0, expanded <= 128*1024*1024 else { throw ViewerError.message("Contenedor Xelis inválido.") }
        _ = try r.bytes(extraLength)
        let input = try r.bytes(compressed)
        // Bound output before decoding; native system zlib, no subprocess or model.
        var output = Data(count: expanded), stream = z_stream()
        guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ViewerError.message("No se pudo iniciar la lectura ZIP.") }
        defer { inflateEnd(&stream) }
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(expanded)
                return inflate(&stream,Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == expanded, stream.total_in == compressed else { throw ViewerError.message("Proyecto Xelis comprimido truncado o inválido.") }
        let actual = output.withUnsafeBytes { crc32(0,$0.bindMemory(to: UInt8.self).baseAddress,uInt(expanded)) }
        guard UInt32(actual) == checksum else { throw ViewerError.message("El bloque Xelis está dañado (CRC incorrecto).") }
        // Validate the one-entry central directory and its matching checksum and sizes.
        var directory = XelisBinary(archive,position: r.position)
        try directory.expect(0x02014b50)
        _ = try directory.bytes(12)
        guard try directory.uint() == checksum, try directory.uint() == compressed, try directory.uint() == expanded else { throw ViewerError.message("Índice ZIP inconsistente.") }
        return output
    }
}

struct XelisBinary {
    let data: Data
    var position: Int = 0
    init(_ data: Data,position: Int = 0) { self.data = data; self.position = position }
    mutating func bytes(_ count: Int) throws -> Data {
        guard position >= 0, count >= 0, position <= data.count, count <= data.count-position else { throw ViewerError.message("Proyecto Xelis truncado.") }
        defer { position += count }
        return data.subdata(in: position..<position+count)
    }
    mutating func word() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) | UInt16(b[1])<<8 }
    mutating func uint() throws -> UInt32 { let b = try bytes(4); return UInt32(b[0]) | UInt32(b[1])<<8 | UInt32(b[2])<<16 | UInt32(b[3])<<24 }
    mutating func expect(_ value: UInt32) throws { guard try uint() == value else { throw ViewerError.message("Estructura Xelis no compatible.") } }
    mutating func float() throws -> Double { let f = Double(Float(bitPattern: try uint())); guard f.isFinite else { throw ViewerError.message("Coordenada Xelis inválida.") }; return f }
    mutating func point() throws -> SIMD3<Double> { try SIMD3(float(),float(),float()) }
    mutating func vector() throws -> SIMD3<Double> { try expect(3); let v = try point(); guard abs(simd_length(v)-1) < 0.01 else { throw ViewerError.message("Ejes Xelis inválidos.") }; return v }
    mutating func count(maximum: Int) throws -> Int { let n = Int(try uint()); guard n > 0, n <= maximum else { throw ViewerError.message("Cantidad de elementos Xelis inválida.") }; return n }
    mutating func string() throws -> String {
        guard try bytes(3) == Data([255,254,255]) else { throw ViewerError.message("Cadena Xelis no compatible.") }
        let n = Int(try bytes(1)[0])
        guard n < 255, let text = String(data: try bytes(n*2),encoding: .utf16LittleEndian) else { throw ViewerError.message("Referencia DICOM Xelis inválida.") }
        return text
    }
    mutating func generalCurveHeader() throws {
        try expect(0x10000003); _ = try uint(); _ = try uint()
        _ = try bytes(1) // MFC BOOL is one byte here.
        for _ in 0..<4 { _ = try float() }
        try expect(3); _ = try point(); try expect(3); _ = try point()
        _ = try float(); _ = try float()
        guard try bytes(1) == Data([1]) else { throw ViewerError.message("Curva Xelis sin datos.") }
    }
    mutating func curve() throws -> XelisCurve {
        let start = position
        try expect(0x10000002)
        for _ in 0..<4 { _ = try float() }
        for _ in 0..<3 { _ = try vector() }
        _ = try point(); _ = try vector(); _ = try point()
        let count = try count(maximum: 20000)
        guard count >= 2, count*44 <= data.count-position else { throw ViewerError.message("Curva Xelis incompleta.") }
        var points: [SIMD3<Double>] = [], verticals: [SIMD3<Double>] = [], tangents: [SIMD3<Double>] = []
        for _ in 0..<count { verticals.append(try vector()); tangents.append(try vector()); points.append(try point()) }
        let controlsCount = try self.count(maximum: 1000)
        var controls: [SIMD3<Double>] = []
        for _ in 0..<controlsCount { controls.append(try point()) }
        let frameCount = try self.count(maximum: 20000)
        var frames: [XelisFrame] = []
        for _ in 0..<frameCount {
            try expect(0x10000001)
            let d = try float(), p = try point(), v = try vector(), t = try vector()
            guard d >= 0, frames.last == nil || d > frames.last!.distance else { throw ViewerError.message("Distancias Xelis inconsistentes.") }
            frames.append(XelisFrame(distance: d,point: p,vertical: v,tangent: t))
        }
        guard try self.count(maximum: 1000) == controlsCount else { throw ViewerError.message("Índice de puntos Xelis inconsistente.") }
        for control in controls { let index = Int(try uint()); guard index < frameCount, simd_distance(control,frames[index].point) < 0.01 else { throw ViewerError.message("Punto de control Xelis sin correspondencia.") } }
        _ = try float() // Saved tolerance; do not recompute the stored curve.
        guard simd_distance(points[0],controls[0]) < 0.001 else { throw ViewerError.message("Extremos Xelis inconsistentes.") }
        return XelisCurve(points: points,verticals: verticals,tangents: tangents,controls: controls,frames: frames,sourceRange: start..<position)
    }
}
