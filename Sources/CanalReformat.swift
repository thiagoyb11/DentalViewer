import Foundation
import CoreGraphics
import simd

extension CTVolume {
    func patientValue(at p: SIMD3<Double>) -> Float? {
        let q = (p-origin)/spacing
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.x >= 0, q.y >= 0, q.z >= 0,
              q.x <= Double(width-1), q.y <= Double(height-1), q.z <= Double(depth-1) else { return nil }
        let z0 = Int(q.z), z1 = min(depth-1,z0+1), t = Float(q.z-Double(z0))
        return interpolated(x: q.x,y: q.y,z: z0)*(1-t)+interpolated(x: q.x,y: q.y,z: z1)*t
    }
    func canalSection(frame: CanalFrame, field: Double, longitudinal: Bool, resolution: Int = 241, center: Double, window: Double) -> CGImage? {
        guard field.isFinite, field > 0, (2...1024).contains(resolution) else { return nil }
        let horizontal = longitudinal ? frame.tangent : frame.horizontal
        var bytes = [UInt8](repeating: 0,count: resolution*resolution)
        for y in 0..<resolution {
            let dy = field*(0.5-Double(y)/Double(resolution-1))
            for x in 0..<resolution {
                let dx = field*(Double(x)/Double(resolution-1)-0.5)
                bytes[y*resolution+x] = displayByte(patientValue(at: frame.center+horizontal*dx+frame.vertical*dy),center: center,window: window)
            }
        }
        return Self.grayImage(bytes: bytes,width: resolution,height: resolution)
    }
}
