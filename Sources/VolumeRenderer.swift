import AppKit
import SwiftUI
import MetalKit

struct VolumeRepresentable: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    func makeNSView(context: Context) -> VolumeMetalView { VolumeMetalView(model: model) }
    func updateNSView(_ view: VolumeMetalView, context: Context) { if model.panelIsVisible(.volume) { view.refresh() } }
}

struct VolumeUniforms {
    var extent: SIMD4<Float>
    var camera: SIMD4<Float> // reserved, reserved, zoom, aspect
    var options: SIMD4<Float> // threshold, ray step, reserved, reserved
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var eye: SIMD4<Float>
}
struct OverlayPrimitive {
    var a: SIMD4<Float> // xyz endpoint, w radius
    var b: SIMD4<Float> // xyz endpoint, w 1=cylinder, 0=capsule
    var color: SIMD4<Float>
}

final class VolumeMetalView: MTKView, MTKViewDelegate {
    let model: ViewerModel
    var queue: MTLCommandQueue?
    var pipeline: MTLRenderPipelineState?
    var canalPipeline: MTLRenderPipelineState?
    var canalBuffer: MTLBuffer?
    var canalVertexCount = 0
    weak var loadedProject: XelisProject?
    var texture: MTLTexture?
    weak var loadedVolume: CTVolume?
    var extent = SIMD4<Float>(1, 1, 1, 0)
    var rotation = VolumeRotation()
    var zoom: Float = 1
    var lastMouse = CGPoint.zero, resetToken = -1
    var rendererError: String?
    var loadGeneration = 0

    init(model: ViewerModel) {
        self.model = model
        let gpu = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: gpu)
        colorPixelFormat = .bgra8Unorm; clearColor = MTLClearColor(red: 0.025, green: 0.025, blue: 0.025, alpha: 1)
        framebufferOnly = false; isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = false
        delegate = self
        guard let gpu else { setError("No se encontró una GPU compatible con Metal."); return }
        queue = gpu.makeCommandQueue()
        do {
            let library = try gpu.makeLibrary(source: Self.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "quadVertex")
            desc.fragmentFunction = library.makeFunction(name: "volumeFragment")
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try gpu.makeRenderPipelineState(descriptor: desc)
            let canals = MTLRenderPipelineDescriptor()
            canals.vertexFunction = library.makeFunction(name: "savedCanalVertex")
            canals.fragmentFunction = library.makeFunction(name: "savedCanalFragment")
            canals.colorAttachments[0].pixelFormat = colorPixelFormat
            canalPipeline = try gpu.makeRenderPipelineState(descriptor: canals)
        } catch { setError("No se pudo iniciar la vista 3D: \(error.localizedDescription)") }
    }
    required init(coder: NSCoder) { fatalError() }
    func setError(_ message: String) {
        rendererError = message
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor; label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -30)])
    }
    override func layout() {
        super.layout()
        // A bounded render resolution keeps interaction responsive even on Retina displays.
        let scale = min(1.5, 900 / max(1, bounds.width, bounds.height))
        drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        setNeedsDisplay(bounds)
    }
    func refresh() {
        if loadedProject !== model.xelisProject || loadedVolume !== model.volume {
            loadedProject = model.xelisProject; canalBuffer = nil; canalVertexCount = 0
            if let project = model.xelisProject, let volume = model.volume {
                let vertices = XelisOverlayGeometry.vertices(project: project,volume: volume)
                canalVertexCount = vertices.count
                canalBuffer = vertices.withUnsafeBytes { raw in
                    guard let address = raw.baseAddress, raw.count > 0 else { return nil }
                    return device?.makeBuffer(bytes: address,length: raw.count,options: .storageModeShared)
                }
            }
        }
        if resetToken != model.resetToken { rotation = VolumeRotation(); zoom = 1; resetToken = model.resetToken }
        if let volume = model.volume, loadedVolume !== volume {
            loadedVolume = volume; loadGeneration += 1; let current = loadGeneration
            texture = nil
            guard let gpu = device else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let stride = max(1, Int(ceil(Double(max(volume.width, volume.height, volume.depth)) / 320)))
                let w = (volume.width + stride - 1) / stride, h = (volume.height + stride - 1) / stride, d = (volume.depth + stride - 1) / stride
                var values = [Float16](repeating: 0, count: w * h * d)
                for z in 0..<d {
                    let vz = min(volume.depth - 1, z * stride)
                    for y in 0..<h { for x in 0..<w {
                        let value = volume.value(x: min(volume.width - 1, x * stride), y: min(volume.height - 1, y * stride), z: vz)
                        values[(z * h + y) * w + x] = Float16(min(65504, max(-65504, value)))
                    } }
                }
                let desc = MTLTextureDescriptor(); desc.textureType = .type3D; desc.pixelFormat = .r16Float
                desc.width = w; desc.height = h; desc.depth = d; desc.usage = .shaderRead; desc.storageMode = .shared
                let texture = gpu.makeTexture(descriptor: desc)
                values.withUnsafeBytes { raw in
                    texture?.replace(region: MTLRegionMake3D(0, 0, 0, w, h, d), mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 2, bytesPerImage: w * h * 2)
                }
                // The downsampled texture uses the same physical field of view as the source volume.
                let physical = SIMD3<Float>(Float(Double(volume.width) * volume.spacing.x), Float(Double(volume.height) * volume.spacing.y), Float(Double(volume.depth) * volume.spacing.z))
                let maximum = max(physical.x, physical.y, physical.z)
                DispatchQueue.main.async {
                    guard self.loadGeneration == current else { return }
                    self.texture = texture
                    self.extent = SIMD4(physical.x / maximum, physical.y / maximum, physical.z / maximum, 0)
                    if texture == nil { self.setError("No se pudo reservar memoria para la reconstrucción 3D.") }
                    self.setNeedsDisplay(self.bounds)
                }
            }
        }
        setNeedsDisplay(bounds)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func encodeVolume(_ encoder: MTLRenderCommandEncoder) {
        guard let pipeline, let texture else { return }
        var primitives = overlayPrimitives()
        let count = primitives.count
        if primitives.isEmpty { primitives.append(OverlayPrimitive(a: .zero,b: .zero,color: .zero)) }
        let buffer = primitives.withUnsafeBytes { device?.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared) }
        var uniforms = VolumeUniforms(extent: extent, camera: SIMD4(0, 0, zoom, Float(drawableSize.width / max(1, drawableSize.height))), options: SIMD4(Float(model.threshold), 0.0025, Float(count), 0), right: SIMD4(rotation.right, 0), up: SIMD4(rotation.up, 0), eye: SIMD4(rotation.camera, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(buffer,offset: 0,index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if model.showXelisCanals, let canalPipeline, let canalBuffer, canalVertexCount > 0 {
            encoder.setRenderPipelineState(canalPipeline)
            encoder.setVertexBuffer(canalBuffer,offset: 0,index: 0)
            encoder.setVertexBytes(&uniforms,length: MemoryLayout<VolumeUniforms>.stride,index: 1)
            encoder.setFragmentBytes(&uniforms,length: MemoryLayout<VolumeUniforms>.stride,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: canalVertexCount)
        }
    }
    func overlayPrimitives() -> [OverlayPrimitive] {
        guard model.showPlanning, let v = model.volume else { return [] }
        let physical = SIMD3(Double(v.width)*v.spacing.x,Double(v.height)*v.spacing.y,Double(v.depth)*v.spacing.z)
        let scale = max(physical.x,physical.y,physical.z)
        let center = v.origin + SIMD3(Double(v.width-1),Double(v.height-1),Double(v.depth-1))*v.spacing/2
        func position(_ point: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>((point-center)/scale) }
        var result: [OverlayPrimitive] = []
        for implant in model.planning.implants {
            let color: SIMD4<Float> = implant.id == model.selectedImplantID ? SIMD4(0.15,0.85,0.80,1) : SIMD4(0.25,0.55,1,1)
            result.append(OverlayPrimitive(a: SIMD4(position(implant.entry.vector),Float(implant.diameter/2/scale)),b: SIMD4(position(implant.apex),1),color: color))
        }
        for canal in model.planning.canals where canal.visible {
            let rgb = canal.color.rgb
            let color = SIMD4<Float>(Float(rgb.x),Float(rgb.y),Float(rgb.z),1)
            if canal.points.count == 1 {
                let point = position(canal.points[0].vector)
                result.append(OverlayPrimitive(a: SIMD4(point,Float(canal.diameter/2/scale)),b: SIMD4(point,0),color: color))
            }
            for (a,b) in zip(canal.path.points,canal.path.points.dropFirst()) {
                result.append(OverlayPrimitive(a: SIMD4(position(a),Float(canal.diameter/2/scale)),b: SIMD4(position(b),0),color: color))
            }
        }
        return result
    }
    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = queue?.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encodeVolume(encoder)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    func snapshotImage() -> CGImage? {
        guard texture != nil, let device, let command = queue?.makeCommandBuffer() else { return nil }
        let width = max(1, Int(drawableSize.width)), height = max(1, Int(drawableSize.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget; desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return nil }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encodeVolume(encoder); encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { rotation = VolumeRotation(); zoom = 1; setNeedsDisplay(bounds) }
        lastMouse = screenPoint(for: event)
    }
    override func mouseDragged(with event: NSEvent) {
        let p = screenPoint(for: event)
        rotation.drag(from: lastMouse, to: p, size: bounds.size)
        lastMouse = p; setNeedsDisplay(bounds)
    }
    func screenPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - bounds.minX, y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
    }
    override func scrollWheel(with event: NSEvent) { zoom = min(4, max(0.3, zoom * exp(Float(event.scrollingDeltaY) * 0.02))); setNeedsDisplay(bounds) }
    override func magnify(with event: NSEvent) { zoom = min(4, max(0.3, zoom * (1 + Float(event.magnification)))); setNeedsDisplay(bounds) }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4 extent; float4 camera; float4 options; float4 right; float4 up; float4 eye; };
    struct Primitive { float4 a; float4 b; float4 color; };
    struct SavedVertex { float4 position; float4 normal; };
    struct SavedOut { float4 position [[position]]; float3 normal; };
    vertex SavedOut savedCanalVertex(uint id [[vertex_id]], device const SavedVertex* points [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        float3 p = points[id].position.xyz;
        SavedOut o;
        o.position = float4(dot(p,u.right.xyz)*u.camera.z/(0.65*u.camera.w),dot(p,u.up.xyz)*u.camera.z/0.65,0,1);
        o.normal = points[id].normal.xyz;
        return o;
    }
    fragment float4 savedCanalFragment(SavedOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float3 light = normalize(u.eye.xyz+u.right.xyz*0.45+u.up.xyz*0.8);
        float shading = 0.55+0.45*abs(dot(normalize(in.normal),light));
        return float4(float3(0.18,1.0,0.35)*shading,1);
    }
    float4 sphereHit(float3 ro,float3 rd,float3 center,float radius) {
        float3 oc=ro-center; float b=dot(oc,rd), c=dot(oc,oc)-radius*radius, disc=b*b-c;
        if(disc<0) return float4(INFINITY,0,0,0);
        float t=-b-sqrt(disc); if(t<0) t=-b+sqrt(disc);
        return t>=0 ? float4(t,normalize(ro+rd*t-center)) : float4(INFINITY,0,0,0);
    }
    float4 tubeHit(float3 ro,float3 rd,Primitive p) {
        float3 a=p.a.xyz,b=p.b.xyz, axis=b-a; float radius=p.a.w, len=length(axis);
        if(len<1e-7) return sphereHit(ro,rd,a,radius);
        axis/=len; float3 pa=ro-a; float h=dot(pa,axis), dh=dot(rd,axis);
        float3 radial=pa-axis*h, dr=rd-axis*dh;
        float aa=dot(dr,dr), bb=dot(radial,dr), cc=dot(radial,radial)-radius*radius;
        float4 hit=float4(INFINITY,0,0,0); float disc=bb*bb-aa*cc;
        if(aa>1e-10 && disc>=0) {
            for(int i=0;i<2;i++) {
                float t=(-bb+(i==0 ? -1.0 : 1.0)*sqrt(disc))/aa; float along=h+t*dh;
                if(t>=0 && t<hit.x && along>=0 && along<=len) hit=float4(t,normalize(radial+dr*t));
            }
        }
        if(p.b.w>0.5) {
            if(abs(dh)>1e-8) for(int i=0;i<2;i++) {
                float cap=i==0 ? 0.0 : len; float t=(cap-h)/dh;
                float3 r=pa+rd*t-axis*cap;
                if(t>=0 && t<hit.x && dot(r,r)<=radius*radius) hit=float4(t,axis*(i==0 ? -1.0 : 1.0));
            }
        } else {
            float4 ha=sphereHit(ro,rd,a,radius), hb=sphereHit(ro,rd,b,radius);
            if(ha.x<hit.x) hit=ha; if(hb.x<hit.x) hit=hb;
        }
        return hit;
    }
    float4 plannedColor(float3 anatomy,float anatomyT,float overlayT,float3 overlay) {
        if(!isfinite(overlayT)) return float4(anatomy,1);
        // Explicit planning overlay: geometry remains visible inside the thresholded bone.
        return float4(mix(anatomy,overlay,overlayT>anatomyT ? 0.78 : 1.0),1);
    }
    vertex VOut quadVertex(uint id [[vertex_id]]) {
        float2 pos[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        VOut o; o.position = float4(pos[id],0,1); o.uv = pos[id]; return o;
    }
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float density(texture3d<half> volume, float3 p, float3 box) {
        return float(volume.sample(linearSampler, p / box + 0.5).r);
    }
    fragment float4 volumeFragment(VOut in [[stage_in]], texture3d<half> volume [[texture(0)]], constant Uniforms& u [[buffer(0)]], device const Primitive* primitives [[buffer(1)]]) {
        float3 box = u.extent.xyz;
        float3 camera = u.eye.xyz;
        float3 right = u.right.xyz;
        float3 up = u.up.xyz;
        float3 origin = camera*2.5 + (right*in.uv.x*u.camera.w + up*in.uv.y)*0.65/u.camera.z;
        float3 direction = -camera;
        float overlayT=INFINITY; float3 overlayColor=float3(0);
        float3 overlayLight=normalize(camera+right*0.45+up*0.8);
        for(int i=0;i<int(u.options.z);i++) {
            float4 hit=tubeHit(origin,direction,primitives[i]);
            if(hit.x<overlayT) { overlayT=hit.x; overlayColor=primitives[i].color.xyz*(0.45+0.55*max(0.0,dot(hit.yzw,overlayLight))); }
        }
        float3 invDir = 1.0 / (direction + float3(1e-7));
        float3 t0 = (-box*0.5-origin)*invDir, t1 = (box*0.5-origin)*invDir;
        float3 lo = min(t0,t1), hi = max(t0,t1);
        float nearT = max(lo.x,max(lo.y,lo.z)), farT = min(hi.x,min(hi.y,hi.z));
        float3 background = float3(0.025,0.030,0.032) + 0.015*(1-in.uv.y)*0.5;
        if (farT <= max(nearT,0.0)) return plannedColor(background,INFINITY,overlayT,overlayColor);
        float step = u.options.y, threshold = u.options.x;
        float previousT = max(nearT,0.0);
        for (float t = previousT; t < farT; t += step) {
            float3 p = origin + direction*t;
            float value = density(volume,p,box);
            if (value > threshold) {
                // Refine the isosurface crossing and shade the local density gradient.
                float left = previousT, rightT = t;
                for (int k=0;k<4;k++) { float mid=(left+rightT)*0.5; if(density(volume,origin+direction*mid,box)>threshold) rightT=mid; else left=mid; }
                p = origin+direction*rightT;
                float3 e = box / float3(volume.get_width(),volume.get_height(),volume.get_depth());
                float3 gradient = float3(
                    density(volume,p+float3(e.x,0,0),box)-density(volume,p-float3(e.x,0,0),box),
                    density(volume,p+float3(0,e.y,0),box)-density(volume,p-float3(0,e.y,0),box),
                    density(volume,p+float3(0,0,e.z),box)-density(volume,p-float3(0,0,e.z),box));
                float3 normal = length(gradient)>0.01 ? -normalize(gradient/e) : camera;
                if(dot(normal,camera)<0) normal=-normal;
                float3 light = normalize(camera+right*0.45+up*0.8);
                float diffuse=max(0.0,dot(normal,light));
                float rim=pow(1.0-max(0.0,dot(normal,camera)),2.0)*0.13;
                float specular=pow(max(0.0,dot(reflect(-light,normal),camera)),28.0)*0.18;
                float3 bone=float3(0.88,0.81,0.69)*(0.22+0.78*diffuse)+rim+specular;
                float fog=clamp((rightT-nearT)/max(0.01,farT-nearT),0.0,1.0)*0.20;
                return plannedColor(mix(bone,background,fog),rightT,overlayT,overlayColor);
            }
            previousT=t;
        }
        return plannedColor(background,INFINITY,overlayT,overlayColor);
    }
    """
}
