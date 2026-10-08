import AppKit
import simd

func runImplantValidation() throws {
    let standardSizes = ImplantDimensions.diameters.flatMap { diameter in ImplantDimensions.lengths.map { (diameter,$0) } }
    for (diameter,length) in [(4.0,10.0),(2.0,4.0),(8.0,25.0),(1.0,50.0),(15.0,1.0)]+standardSizes {
        let mesh = ImplantGeometry.mesh(diameter: diameter,length: length)
        expect(!mesh.points.isEmpty && mesh.triangles.count%3 == 0,"Threaded implant has a complete triangle mesh")
        let radial = mesh.points.map { hypot($0.x,$0.y) }
        expect(abs(radial.max()!-diameter/2) < 1e-9 && radial.allSatisfy({ $0 <= diameter/2+1e-9 }),"Configured diameter bounds the outermost thread, including the neck")
        expect(mesh.points.map(\.z).min() == 0 && mesh.points.map(\.z).max() == length,"Threaded body starts at entry and ends at the exact configured apex")
        expect(mesh.normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs(simd_length($0)-1) < 1e-9 }),"Thread and cap normals stay finite at short, thin and large dimensions")
        expect(mesh.triangles.allSatisfy({ mesh.points.indices.contains($0) }),"All implant triangles reference valid vertices")
        let endRing = mesh.rings.last!.map { mesh.points[$0] }
        expect(endRing.allSatisfy({ hypot($0.x,$0.y) < diameter*0.4 }),"Rounded apical tip is narrower than the body")
        for angles in [(0.0,0.0),(35.0,-20.0),(85.0,85.0)] {
            var implant = PlannedImplant(entry: PatientPoint(SIMD3(17,-23,31)))
            implant.diameter = diameter; implant.length = length; implant.lateralAngle = angles.0; implant.anteriorAngle = angles.1
            let frame = ImplantGeometry.Frame(implant)
            expect(simd_distance(frame.point(SIMD3(0,0,length)),implant.apex) < 1e-9,"Mesh apex follows the stored entry, length and both inclinations")
            let longitudinal = ImplantGeometry.section(implant,center: implant.entry.vector,normal: frame.y).flatMap { $0 }.map(frame.local)
            expect(!longitudinal.isEmpty,"A longitudinal plane intersects the full threaded body")
            expect(abs(longitudinal.map(\.z).min()!) < 1e-8 && abs(longitudinal.map(\.z).max()!-length) < 1e-8,"Longitudinal cut includes exactly the configured length, without capsule end extensions")
            expect(longitudinal.allSatisfy({ abs($0.y) < 1e-8 && hypot($0.x,$0.y) <= diameter/2+1e-8 }),"Slice contours remain on the physical plane and within the diameter envelope")
            let transverse = ImplantGeometry.section(implant,center: frame.point(SIMD3(0,0,length*0.08)),normal: frame.axis).flatMap { $0 }.map(frame.local)
            expect(!transverse.isEmpty && abs(transverse.map(\.x).max()!-transverse.map(\.x).min()!-diameter) < 1e-8,"Axial neck section shows the configured exterior diameter")
            expect(ImplantGeometry.section(implant,center: frame.point(SIMD3(0,0,-0.01)),normal: frame.axis).isEmpty,"A plane before entry contains no implant geometry")
            expect(ImplantGeometry.section(implant,center: frame.point(SIMD3(0,0,length+0.01)),normal: frame.axis).isEmpty,"A plane beyond the apex contains no implant geometry")
            expect(ImplantGeometry.section(implant,center: implant.entry.vector+frame.y*(diameter/2+0.01),normal: frame.y).isEmpty,"An off-axis plane outside the diameter shows no implant")
        }
    }
    expect(ImplantGeometry.mesh(diameter: .nan,length: 10).points.isEmpty && ImplantGeometry.mesh(diameter: 4,length: .infinity).points.isEmpty,"Invalid implant dimensions cannot create non-finite mesh geometry")
    let folder = URL(fileURLWithPath: "output/test-fixtures/implant-projection")
    try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
    let profile = CalibrationProfile(bits: 16,stored: 16,signed: false,implicit: false,inverted: false,spacing: SIMD3(1,1,1),origin: .zero,slope: 1,intercept: 0)
    for z in 0..<16 { try calibrationSlice(profile,z: z,width: 32,height: 32).write(to: folder.appendingPathComponent("slice-\(z).dcm")) }
    let volume = try CTVolume(series: StudyLoader.scan(folder).series[0]), model = ViewerModel()
    model.volume = volume
    model.archCurve = try ArchCurve(points: [CGPoint(x: 16,y: 0),CGPoint(x: 16,y: 16),CGPoint(x: 16,y: 31)],spacing: SIMD2(1,1))
    let panoramic = DentalImagesView(model: model,panoramic: true)
    panoramic.renderedVolume = volume; panoramic.renderedCurve = model.archCurve; panoramic.renderedField = 25
    panoramic.images = [volume.panoramic(curve: model.archCurve!,thickness: 0,maximum: false,center: 0,window: 1000)!]
    let projectedImplant = PlannedImplant(entry: PatientPoint(SIMD3(16,16,12)))
    model.planning.implants = [projectedImplant]; model.selectedImplantID = projectedImplant.id
    for (diameter,length) in standardSizes+[(3.75,12.25)] {
        model.updateImplant(\.diameter,value: diameter); model.updateImplant(\.length,value: length)
        let edited = model.selectedImplant!
        expect(edited.diameter == diameter && edited.length == length,"Standard presets and custom decimals reach the planning model without rounding")
        let document = PlanningDocument(volume: volume,planning: model.planning)
        let restored = try JSONDecoder().decode(PlanningDocument.self,from: JSONEncoder().encode(document))
        try restored.validate(for: volume)
        expect(restored.planning.implants[0] == edited,"Every preset and custom size persists without moving the implant entry or changing its identifier")
    }
    let beforeInvalid = model.selectedImplant!
    model.updateImplant(\.diameter,value: .nan); model.updateImplant(\.length,value: .infinity)
    expect(model.selectedImplant == beforeInvalid,"Custom dimensions reject non-finite input without corrupting planning")
    model.updateImplant(\.diameter,value: -1); model.updateImplant(\.length,value: 500)
    expect(model.selectedImplant!.diameter == 1 && model.selectedImplant!.length == 50,"Custom dimensions remain within the supported planning bounds")
    let projection = panoramic.dentalImplantContours(projectedImplant,cell: 0).flatMap { $0 }
    expect(abs(projection.map(\.y).max()!-projection.map(\.y).min()!-4) < 1e-8,"Panoramic silhouette extends along the developed arch instead of collapsing across its normal")
    for size in [CGSize(width: 400,height: 300),CGSize(width: 1000,height: 650)] {
        panoramic.frame = CGRect(origin: .zero,size: size)
        let mapped = projection.compactMap { panoramic.dentalProjection($0,cell: 0) }
        let width = mapped.map(\.x).max()!-mapped.map(\.x).min()!, rect = panoramic.imageRect(0)
        expect(width > 5 && mapped.allSatisfy(rect.contains),"Actual panorama mapping keeps the whole implant visible at normal and expanded panel sizes")
        expect(abs(width/(rect.width/model.archCurve!.imageWidth)-4) <= model.archCurve!.step+1e-8,"Panorama width follows the 4 mm outer diameter within its column sampling resolution")
    }
    // Capture the actual contour renderer at two scales; these fixtures contain no patient data.
    let implant = PlannedImplant(entry: PatientPoint(.zero)), frame = ImplantGeometry.Frame(implant)
    let contours = ImplantGeometry.section(implant,center: .zero,normal: frame.y)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 900,pixelsHigh: 660,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedWhite: 0.06,alpha: 1).setFill(); NSBezierPath(rect: CGRect(x: 0,y: 0,width: 900,height: 660)).fill()
    for (offset,scale) in [(220.0,45.0),(660.0,30.0)] {
        ImplantOverlay.draw(contours,color: .systemTeal,project: { point in
            let p = frame.local(point)
            return CGPoint(x: offset+p.x*scale,y: 590-p.z*scale)
        })
        ("Ø 4.0 × 10.0 mm" as NSString).draw(at: CGPoint(x: offset-90,y: 70),withAttributes: [.font:NSFont.systemFont(ofSize: 17),.foregroundColor:NSColor.white])
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: "output/implant-contour-preview.png"))
}
