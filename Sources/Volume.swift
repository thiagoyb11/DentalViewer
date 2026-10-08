import Foundation
import CoreGraphics

enum Plane: String, CaseIterable, Identifiable {
    case axial = "Axial", coronal = "Coronal", sagittal = "Sagital"
    var id: String { rawValue }
}

final class CTVolume {
    let width: Int, height: Int, depth: Int
    let spacing: SIMD3<Double>
    let origin: SIMD3<Double>
    let voxels: [UInt16]
    let slopes: [Float], intercepts: [Float]
    let signed: Bool, bitsStored: Int
    let patient: String, studyDate: String, description: String
    let studyUID: String, seriesUID: String
    let sourceSOPUIDs: Set<String>
    let defaultCenter: Double, defaultWidth: Double
    let monochrome1: Bool

    init(series: DICOMSeries, progress: (Double) -> Void = { _ in }) throws {
        guard let first = series.images.first, series.images.count >= 2 else { throw ViewerError.message("Se necesitan al menos dos cortes CT para reconstruir el volumen.") }
        let w = first.columns, h = first.rows
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { throw ViewerError.message("Dimensiones de imagen inválidas.") }
        let ori = first.orientation, sp = first.numbers(0x00280030)
        // Only axial LPS is supported; refusing other geometries prevents wrong labels or measurements.
        guard ori.count == 6, zip(ori, [1.0, 0, 0, 0, 1, 0]).allSatisfy({ abs($0 - $1) < 0.0001 }),
              sp.count == 2, sp.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw ViewerError.message("Esta versión requiere una serie axial con orientación DICOM LPS (1,0,0,0,1,0). Las series oblicuas todavía no están implementadas.")
        }
        let images = series.images.sorted { ($0.position.last ?? 0) < ($1.position.last ?? 0) }
        guard images.allSatisfy({ $0.position.count == 3 && $0.position.allSatisfy(\.isFinite) }) else { throw ViewerError.message("Falta la posición física de los cortes.") }
        let steps = zip(images.dropFirst(), images).map { $0.position[2] - $1.position[2] }
        let sortedSteps = steps.sorted(), dz = sortedSteps[sortedSteps.count / 2]
        guard dz > 0, steps.allSatisfy({ abs($0 - dz) <= max(0.0001, dz * 0.01) }) else {
            throw ViewerError.message("La serie tiene cortes duplicados, faltantes o espaciado irregular; no se reconstruirá un volumen con geometría incorrecta.")
        }
        let bits = first.integer(0x00280100), stored = first.integer(0x00280101), high = first.integer(0x00280102)
        guard [8, 16].contains(bits), stored > 0, stored <= bits, high == stored - 1 else { throw ViewerError.message("Formato de píxel no compatible.") }
        let isSigned = first.integer(0x00280103) == 1
        guard w * h * images.count <= 600_000_000 else { throw ViewerError.message("El estudio excede el límite de memoria de esta versión.") }
        var pixels = [UInt16](repeating: 0, count: w * h * images.count)
        var ss: [Float] = [], ii: [Float] = []
        let mask = UInt16(truncatingIfNeeded: (UInt32(1) << stored) - 1)
        for (z, image) in images.enumerated() {
            let pixelSpacing = image.numbers(0x00280030)
            guard image.columns == w, image.rows == h, image.orientation.count == 6,
                  zip(image.orientation, ori).allSatisfy({ abs($0 - $1) < 0.0001 }),
                  pixelSpacing.count == 2, zip(pixelSpacing, sp).allSatisfy({ abs($0 - $1) < 0.0001 }),
                  abs(image.position[0] - images[0].position[0]) < 0.0001,
                  abs(image.position[1] - images[0].position[1]) < 0.0001,
                  image.integer(0x00280002) == 1,
                  ["MONOCHROME1", "MONOCHROME2"].contains(image.string(0x00280004)),
                  image.string(0x00280004) == first.string(0x00280004),
                  image.integer(0x00280100) == bits, image.integer(0x00280101) == stored,
                  image.integer(0x00280102) == high, image.integer(0x00280103) == first.integer(0x00280103),
                  (Int(image.string(0x00280008)) ?? 1) == 1,
                  image.string(0x0020000D) == first.string(0x0020000D),
                  let range = image.pixels, range.count == w * h * (bits / 8) else {
                throw ViewerError.message("Cortes incompatibles o píxeles incompletos dentro de la serie.")
            }
            let slope = Float(image.numbers(0x00281053).first ?? 1), intercept = Float(image.numbers(0x00281052).first ?? 0)
            guard slope.isFinite, slope != 0, intercept.isFinite else { throw ViewerError.message("Escala de intensidad inválida.") }
            ss.append(slope); ii.append(intercept)
            image.data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let offset = z * w * h
                for p in 0..<w * h {
                    let i = range.lowerBound + p * (bits / 8)
                    pixels[offset + p] = (UInt16(bytes[i]) | (bits == 16 ? UInt16(bytes[i + 1]) << 8 : 0)) & mask
                }
            }
            if z % 8 == 0 { progress(Double(z + 1) / Double(images.count)) }
        }
        width = w; height = h; depth = images.count; spacing = SIMD3(sp[1], sp[0], dz)
        origin = SIMD3(images[0].position[0], images[0].position[1], images[0].position[2])
        voxels = pixels; slopes = ss; intercepts = ii; signed = isSigned; bitsStored = stored
        patient = first.string(0x00100010).replacingOccurrences(of: "^", with: " ").trimmingCharacters(in: .whitespaces)
        studyDate = first.string(0x00080020); description = first.string(0x0008103E)
        studyUID = first.string(0x0020000D); seriesUID = first.seriesUID
        sourceSOPUIDs = Set(images.map { $0.string(0x00080018) })
        let wc = first.numbers(0x00281050).first ?? 600
        let ww = first.numbers(0x00281051).first ?? 2800
        guard wc.isFinite, ww.isFinite, ww >= 1 else { throw ViewerError.message("Centro o ventana DICOM inválidos.") }
        defaultCenter = wc; defaultWidth = ww
        monochrome1 = first.string(0x00280004) == "MONOCHROME1"
        progress(1)
    }

    @inline(__always) func value(x: Int, y: Int, z: Int) -> Float {
        let raw = Int(voxels[(z * height + y) * width + x])
        let sample = signed && raw & (1 << (bitsStored - 1)) != 0 ? raw - (1 << bitsStored) : raw
        return Float(sample) * slopes[z] + intercepts[z]
    }
    func dimensions(_ plane: Plane) -> (Int, Int, Double, Double) {
        switch plane {
        case .axial: return (width, height, spacing.x, spacing.y)
        case .coronal: return (width, depth, spacing.x, spacing.z)
        case .sagittal: return (height, depth, spacing.y, spacing.z)
        }
    }
    func slice(_ plane: Plane, index: Int, center: Double, window: Double) -> CGImage? {
        let (w, h, _, _) = dimensions(plane)
        var bytes = [UInt8](repeating: 0, count: w * h)
        // DICOM linear window mapping, including the width=1 threshold case.
        let c = Float(center - 0.5), ww = Float(max(1, window) - 1)
        for v in 0..<h {
            for u in 0..<w {
                let value: Float
                switch plane {
                case .axial: value = self.value(x: u, y: v, z: min(depth - 1, max(0, index)))
                case .coronal: value = self.value(x: u, y: min(height - 1, max(0, index)), z: depth - 1 - v)
                case .sagittal: value = self.value(x: min(width - 1, max(0, index)), y: u, z: depth - 1 - v)
                }
                let normalized = ww == 0 ? (value > c ? Float(1) : 0) : min(1, max(0, (value - c) / ww + 0.5))
                bytes[v * w + u] = UInt8((monochrome1 ? 1 - normalized : normalized) * 255)
            }
        }
        return Self.grayImage(bytes: bytes, width: w, height: h)
    }
    static func grayImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    func interpolated(x: Double, y: Double, z: Int) -> Float {
        let x = min(Double(width - 1), max(0, x)), y = min(Double(height - 1), max(0, y))
        let x0 = Int(x), y0 = Int(y), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        return (value(x: x0, y: y0, z: z) * (1 - tx) + value(x: x1, y: y0, z: z) * tx) * (1 - ty)
            + (value(x: x0, y: y1, z: z) * (1 - tx) + value(x: x1, y: y1, z: z) * tx) * ty
    }
}
