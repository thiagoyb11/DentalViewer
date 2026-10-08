import Foundation

enum ViewerError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct DICOMImage {
    let url: URL
    let data: Data
    let values: [UInt32: Data]
    let pixels: Range<Int>?
    let syntax: String
    func string(_ tag: UInt32) -> String {
        guard let bytes = values[tag] else { return "" }
        return (String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0\r\n"))
    }
    func numbers(_ tag: UInt32) -> [Double] { string(tag).split(separator: "\\").compactMap { Double($0) } }
    func integer(_ tag: UInt32) -> Int {
        guard let v = values[tag], v.count >= 2 else { return 0 }
        return Int(v[v.startIndex]) | Int(v[v.startIndex + 1]) << 8
    }
    var isCT: Bool { string(0x00080016) == "1.2.840.10008.5.1.4.1.1.2" }
    var seriesUID: String { string(0x0020000E) }
    var rows: Int { integer(0x00280010) }
    var columns: Int { integer(0x00280011) }
    var position: [Double] { numbers(0x00200032) }
    var orientation: [Double] { numbers(0x00200037) }
}

enum DICOMReader {
    static let longVR: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT"]
    static let captured: Set<UInt32> = [0x00080018, 0x00200052, 0x75730010, 0x75731000, 0x75731001, 0x75731003, 0x75731004, 0x00080016, 0x00080020, 0x00080060, 0x0008103E,
        0x00100010, 0x00100020, 0x0020000D, 0x0020000E, 0x00200013, 0x00200032, 0x00200037,
        0x00180050, 0x00280002, 0x00280004, 0x00280008, 0x00280010, 0x00280011, 0x00280030,
        0x00280100, 0x00280101, 0x00280102, 0x00280103, 0x00281050, 0x00281051, 0x00281052, 0x00281053]

    static func read(_ url: URL) throws -> DICOMImage? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 132, data[128..<132] == Data("DICM".utf8) else { return nil }
        return try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func u16(_ p: Int) -> UInt32 { UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 }
            func u32(_ p: Int) -> UInt32 { u16(p) | u16(p + 2) << 16 }
            var p = 132
            var syntax = "1.2.840.10008.1.2"
            var tags: [UInt32: Data] = [:]
            var pixelRange: Range<Int>?
            func header(_ explicit: Bool) throws -> (UInt32, String, UInt32) {
                guard p + 8 <= data.count else { throw ViewerError.message("Cabecera DICOM truncada: \(url.lastPathComponent)") }
                let tag = u16(p) << 16 | u16(p + 2)
                if tag >> 16 == 0xFFFE { let n = u32(p + 4); p += 8; return (tag, "", n) }
                if !explicit { let n = u32(p + 4); p += 8; return (tag, "", n) }
                let vr = String(bytes: [bytes[p + 4], bytes[p + 5]], encoding: .ascii) ?? ""
                if longVR.contains(vr) {
                    guard p + 12 <= data.count else { throw ViewerError.message("DICOM truncado.") }
                    let n = u32(p + 8); p += 12; return (tag, vr, n)
                }
                let n = u16(p + 6); p += 8; return (tag, vr, n)
            }
            func skip(_ length: UInt32, explicit: Bool, depth: Int) throws {
                guard depth < 64 else { throw ViewerError.message("Secuencias DICOM demasiado profundas.") }
                if length != UInt32.max {
                    guard Int(length) <= data.count - p else { throw ViewerError.message("Longitud DICOM fuera del archivo.") }
                    p += Int(length); return
                }
                while p < data.count {
                    let (tag, _, n) = try header(explicit)
                    if tag == 0xFFFEE00D || tag == 0xFFFEE0DD {
                        guard n == 0 else { throw ViewerError.message("Delimitador DICOM inválido.") }; return
                    }
                    try skip(n, explicit: explicit, depth: depth + 1)
                }
                throw ViewerError.message("Secuencia DICOM sin cierre.")
            }
            while p < data.count {
                guard p + 8 <= data.count else { throw ViewerError.message("DICOM truncado.") }
                let meta = u16(p) == 2
                if !meta && !["1.2.840.10008.1.2", "1.2.840.10008.1.2.1"].contains(syntax) && !syntax.hasPrefix("1.2.840.10008.1.2.4.") && syntax != "1.2.840.10008.1.2.5" {
                    // Deflated/big-endian/unknown datasets cannot be read as explicit little endian.
                    return DICOMImage(url: url, data: data, values: [:], pixels: nil, syntax: syntax)
                }
                let explicit = meta || syntax != "1.2.840.10008.1.2"
                let (tag, _, n) = try header(explicit)
                if tag == 0x00020010 {
                    guard n != UInt32.max, Int(n) <= data.count - p else { throw ViewerError.message("Transfer Syntax inválida.") }
                    syntax = String(decoding: data[p..<p + Int(n)], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
                }
                if tag == 0x7FE00010 {
                    if n == UInt32.max { break } // Encapsulated JPEG: retain project tags without decoding its preview.
                    guard Int(n) <= data.count - p else { throw ViewerError.message("Datos de píxeles incompletos.") }
                    pixelRange = p..<p + Int(n); break
                }
                if captured.contains(tag), n != UInt32.max {
                    guard Int(n) <= data.count - p else { throw ViewerError.message("DICOM truncado.") }
                    tags[tag] = data.subdata(in: p..<p + Int(n))
                }
                try skip(n, explicit: explicit, depth: 0)
            }
            return DICOMImage(url: url, data: data, values: tags, pixels: pixelRange, syntax: syntax)
        }
    }
}

struct DICOMSeries: Identifiable {
    var id: String
    var images: [DICOMImage]
    var label: String { "\(images.first?.string(0x0008103E) ?? "CT") · \(images.count) cortes" }
}
struct StudyScan {
    var series: [DICOMSeries]
    var compressedFiles: Int
    var projectFiles: Int
    var xelisProjects: [DICOMImage] = []
    var failures: [String]
}
enum StudyLoader {
    static func scan(_ folder: URL) throws -> StudyScan {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw ViewerError.message("No se pudo leer la carpeta.")
        }
        var groups: [String: [DICOMImage]] = [:], compressed = 0, projects = 0
        var failures: [String] = []
        var xelisProjects: [DICOMImage] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.pathExtension.uppercased() == "XPV" { projects += 1; continue }
            do {
                guard let image = try DICOMReader.read(url) else { continue }
                if image.string(0x75730010) == "MEVISYS", image.values[0x75731004] != nil { xelisProjects.append(image); continue }
                if image.pixels == nil && !["1.2.840.10008.1.2", "1.2.840.10008.1.2.1"].contains(image.syntax) { compressed += 1; continue }
                guard image.isCT, image.pixels != nil else { continue }
                guard !image.seriesUID.isEmpty else { failures.append("Imagen CT sin identificador de serie."); continue }
                groups[image.seriesUID, default: []].append(image)
            } catch { failures.append(error.localizedDescription) }
        }
        let series = groups.map { DICOMSeries(id: $0.key, images: $0.value) }.sorted { $0.images.count > $1.images.count }
        guard !series.isEmpty else {
            throw ViewerError.message("No se encontraron cortes CT DICOM compatibles. Esta versión lee CT monocromático sin compresión, de 8 o 16 bits.\(compressed > 0 ? " Se encontraron \(compressed) archivos comprimidos." : "")\(failures.isEmpty ? "" : " \(failures[0])")")
        }
        return StudyScan(series: series, compressedFiles: compressed, projectFiles: projects, xelisProjects: xelisProjects, failures: failures)
    }
}
