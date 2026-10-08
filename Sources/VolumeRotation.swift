import Foundation
import CoreGraphics
import simd

/// Camera-to-patient basis. Dragging rotates the anatomy in screen space,
/// regardless of the current viewing angle or anatomical axes.
struct VolumeRotation {
    var orientation: simd_quatf = initialOrientation
    static var initialOrientation: simd_quatf {
        let yaw: Float = 0.25, pitch: Float = 0.18
        let camera = SIMD3<Float>(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), camera))
        return simd_quatf(simd_float3x3(columns: (right, simd_cross(camera, right), camera)))
    }
    var right: SIMD3<Float> { orientation.act(SIMD3(1, 0, 0)) }
    var up: SIMD3<Float> { orientation.act(SIMD3(0, 1, 0)) }
    var camera: SIMD3<Float> { orientation.act(SIMD3(0, 0, 1)) }

    /// Points use screen coordinates: x goes right and y goes down.
    mutating func drag(from start: CGPoint, to end: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let a = Self.trackballPoint(start, size: size), b = Self.trackballPoint(end, size: size)
        guard simd_length_squared(a - b) > 1e-12 else { return }
        let movement = simd_quatf(from: a, to: b)
        // The ray renderer orbits the camera. Invert the screen-space object rotation.
        orientation = simd_normalize(orientation * movement.inverse)
    }
    static func trackballPoint(_ point: CGPoint, size: CGSize) -> SIMD3<Float> {
        let radius = Float(min(size.width, size.height) * 0.5)
        let x = Float(point.x - size.width * 0.5) / radius
        let y = Float(size.height * 0.5 - point.y) / radius
        let r2 = x * x + y * y
        if r2 <= 1 { return SIMD3(x, y, sqrt(max(0, 1 - r2))) }
        return simd_normalize(SIMD3(x, y, 0))
    }
}
