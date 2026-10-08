import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import Metal

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); expect(false, message) } catch { checks += 1 }
}
func le16(_ v: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]) }
func le32(_ v: UInt32) -> Data { le16(UInt16(truncatingIfNeeded: v)) + le16(UInt16(truncatingIfNeeded: v >> 16)) }
func tag(_ t: UInt32) -> Data { le16(UInt16(t >> 16)) + le16(UInt16(truncatingIfNeeded: t)) }
func element(_ t: UInt32, _ vr: String, _ value: Data, implicit: Bool = false) -> Data {
    var value = value
    if value.count % 2 != 0 { value.append(vr == "UI" ? 0 : 32) }
    if implicit { return tag(t) + le32(UInt32(value.count)) + value }
    let prefix = tag(t) + Data(vr.utf8)
    return prefix + (DICOMReader.longVR.contains(vr) ? le16(0) + le32(UInt32(value.count)) : le16(UInt16(value.count))) + value
}
func fixture(z: Double, implicit: Bool = false, signed: Bool = false, pixels: [UInt16] = [0, 100, 200, 300], slope: Double = 1, intercept: Double = -1024) -> Data {
    var b = Data(repeating: 0, count: 128) + Data("DICM".utf8)
    b += element(0x00020010, "UI", Data((implicit ? "1.2.840.10008.1.2" : "1.2.840.10008.1.2.1").utf8))
    func add(_ t: UInt32, _ vr: String, _ value: Data) { b += element(t, vr, value, implicit: implicit) }
    func text(_ t: UInt32, _ vr: String, _ s: String) { add(t, vr, Data(s.utf8)) }
    text(0x00080016, "UI", "1.2.840.10008.5.1.4.1.1.2")
    text(0x0020000D, "UI", "1.2.3.4"); text(0x0020000E, "UI", "1.2.3.5")
    // An undefined-length sequence with an undefined-length item containing a patient name.
    b += tag(0x00101002) + (implicit ? le32(UInt32.max) : Data("SQ".utf8) + le16(0) + le32(UInt32.max))
    b += tag(0xFFFEE000) + le32(UInt32.max)
    b += element(0x00100010, "PN", Data("NESTED^NAME".utf8), implicit: implicit)
    b += tag(0xFFFEE00D) + le32(0) + tag(0xFFFEE0DD) + le32(0)
    text(0x00100010, "PN", "TEST^PATIENT")
    text(0x00200032, "DS", "0\\0\\\(z)"); text(0x00200037, "DS", "1\\0\\0\\0\\1\\0")
    text(0x00280030, "DS", "0.5\\0.25")
    text(0x00280004, "CS", "MONOCHROME2")
    for (t, v): (UInt32, UInt16) in [(0x00280002,1), (0x00280010,2), (0x00280011,2), (0x00280100,16), (0x00280101,12), (0x00280102,11), (0x00280103,signed ? 1 : 0)] { add(t,"US",le16(v)) }
    text(0x00281052, "DS", "\(intercept)"); text(0x00281053, "DS", "\(slope)")
    add(0x7FE00010, "OW", pixels.reduce(Data()) { $0 + le16($1) })
    return b
}
func image(_ data: Data, name: String) throws -> DICOMImage {
    let url = URL(fileURLWithPath: "output/test-fixtures/\(name)")
    try data.write(to: url)
    guard let image = try DICOMReader.read(url) else { throw ViewerError.message("Fixture not parsed") }; return image
}
try FileManager.default.createDirectory(atPath: "output/test-fixtures", withIntermediateDirectories: true)
for implicit in [false, true] {
    let a = try image(fixture(z: 0, implicit: implicit), name: "a-\(implicit).dcm")
    let b = try image(fixture(z: 1, implicit: implicit, pixels: [400, 500, 600, 700]), name: "b-\(implicit).dcm")
    expect(a.string(0x00100010) == "TEST^PATIENT", "Undefined-length sequence must not leak nested metadata")
    let v = try CTVolume(series: DICOMSeries(id: "test", images: [b,a]))
    expect(v.width == 2 && v.height == 2 && v.depth == 2, "Dimensions")
    expect(v.spacing == SIMD3(0.25,0.5,1), "DICOM row/column spacing order")
    expect(v.value(x: 1,y: 1,z: 0) == -724 && v.value(x: 0,y: 0,z: 1) == -624, "Physical order and rescale")
    let coronal = v.slice(.coronal, index: 0, center: -624, window: 400)!
    expect(coronal.width == 2 && coronal.height == 2, "Coronal dimensions")
    let bytes = coronal.dataProvider!.data! as Data
    expect(bytes[0] > bytes[2], "Superior must be at the top of coronal image")
    expectThrows("Duplicate slice positions") { _ = try CTVolume(series: DICOMSeries(id: "bad", images: [a,a])) }
    let missing = try image(fixture(z: 3, implicit: implicit), name: "missing-\(implicit).dcm")
    expectThrows("Missing slice must fail geometry validation") { _ = try CTVolume(series: DICOMSeries(id: "bad", images: [a,b,missing])) }
}
let sa = try image(fixture(z: 0, signed: true, pixels: [0xFFF,0x800,0x7FF,0], slope: 2, intercept: 10), name: "signed-a.dcm")
let sb = try image(fixture(z: 1, signed: true, pixels: [0,0,0,0], slope: 2, intercept: 10), name: "signed-b.dcm")
let signed = try CTVolume(series: DICOMSeries(id: "signed", images: [sa,sb]))
expect(signed.value(x: 0,y: 0,z: 0) == 8, "12-bit negative sign extension")
expect(signed.value(x: 1,y: 0,z: 0) == -4086, "12-bit minimum signed value")
expect(signed.value(x: 0,y: 1,z: 0) == 4104, "12-bit maximum signed value")
var truncated = fixture(z: 0); truncated.removeLast()
expectThrows("Truncated pixels must be rejected") { _ = try image(truncated, name: "truncated.dcm") }
// Follow the screen projection of a visible surface point. These checks remain
// independent of patient axes and catch inverted controls after arbitrary turns.
let viewport = CGSize(width: 600, height: 400), middle = CGPoint(x: 300, y: 200)
let startingOrientations = [VolumeRotation.initialOrientation,
    simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)),
    simd_quatf(angle: 1.8, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))]
for initial in startingOrientations {
    for (end, direction) in [(CGPoint(x: 340,y: 200), SIMD2<Float>(1,0)),
                              (CGPoint(x: 260,y: 200), SIMD2<Float>(-1,0)),
                              (CGPoint(x: 300,y: 240), SIMD2<Float>(0,-1)),
                              (CGPoint(x: 300,y: 160), SIMD2<Float>(0,1)),
                              (CGPoint(x: 330,y: 230), SIMD2<Float>(1,-1))] {
        var rotation = VolumeRotation(orientation: initial)
        let surfacePoint = initial.act(SIMD3<Float>(0,0,1))
        rotation.drag(from: middle, to: end, size: viewport)
        let screen = rotation.orientation.inverse.act(surfacePoint)
        expect(simd_dot(SIMD2(screen.x,screen.y), direction) > 0.1, "Visible anatomy follows mouse direction at any orientation")
        expect(abs(simd_length(rotation.orientation.vector) - 1) < 0.00001, "Rotation stays normalized")
        rotation.drag(from: end, to: middle, size: viewport)
        expect(abs(simd_dot(rotation.orientation.vector, initial.vector)) > 0.99999, "Reversing drag restores orientation")
    }
}
var poleRotation = VolumeRotation()
for _ in 0..<1000 { poleRotation.drag(from: middle, to: CGPoint(x: 305,y: 195), size: viewport) }
expect(poleRotation.orientation.vector.x.isFinite && abs(simd_length(poleRotation.orientation.vector) - 1) < 0.00001, "Many full turns stay stable without a pitch clamp")
let zero = SIMD3<Double>(0,0,0)
expect(abs(PlanningGeometry.segmentDistance(zero,SIMD3(10,0,0),SIMD3(0,3,0),SIMD3(10,3,0))-3)<1e-9, "Parallel segment distance")
expect(PlanningGeometry.segmentDistance(zero,SIMD3(10,0,0),SIMD3(5,-5,0),SIMD3(5,5,0))<1e-9, "Crossing segment distance")
expect(abs(PlanningGeometry.segmentDistance(zero,SIMD3(10,0,0),SIMD3(5,-5,4),SIMD3(5,5,4))-4)<1e-9, "Skew segment distance")
expect(abs(PlanningGeometry.segmentDistance(zero,zero,SIMD3(3,4,0),SIMD3(3,4,0))-5)<1e-9, "Degenerate point distances")
var implant = PlannedImplant(entry: PatientPoint(SIMD3(5,0,10)))
expect(implant.apex == SIMD3(5,0,0), "Implant default axis and length use millimeters")
implant.lateralAngle = 45
expect(abs(simd_length(implant.apex-implant.entry.vector)-10)<1e-9 && implant.apex.x>implant.entry.x, "Tilt preserves implant length")
implant.lateralAngle = 0
let canal = NerveCanal(name: "Test",diameter: 2,points: [PatientPoint(SIMD3(0,5,5)),PatientPoint(SIMD3(10,5,5))])
expect(abs(PlanningGeometry.separation(implant: implant,canals: [canal])!-2)<1e-9, "Clearance subtracts both physical radii")
expect(PlanningGeometry.separation(implant: implant,canals: []) == nil, "No inferred nerve clearance without a traced canal")
let doc = PlanningDocument(volume: signed,planning: PlanningData(implants: [implant],canals: [canal]))
let decoded = try JSONDecoder().decode(PlanningDocument.self,from: JSONEncoder().encode(doc))
try decoded.validate(for: signed)
expect(decoded.planning == doc.planning, "Planning JSON preserves points, implant dimensions and IDs")
var foreign = decoded; foreign.seriesUID = "other"
expectThrows("Planning must reject a different DICOM series") { try foreign.validate(for: signed) }
var badGeometry = decoded; badGeometry.spacing.x = 99
expectThrows("Planning must reject different physical spacing") { try badGeometry.validate(for: signed) }
var invalidPlan = decoded; invalidPlan.planning.implants[0].diameter = -1
expectThrows("Planning must reject invalid implant geometry") { try invalidPlan.validate(for: signed) }
var tooMany = decoded; tooMany.planning.canals[0].points = (0..<300).map { PatientPoint(SIMD3(Double($0),0,0)) }
expectThrows("Planning must reject data beyond the renderer limit") { try tooMany.validate(for: signed) }
let ua = try image(fixture(z: 0),name: "dental-a.dcm")
let ub = try image(fixture(z: 1,pixels: [400,500,600,700]),name: "dental-b.dcm")
let dental = try CTVolume(series: DICOMSeries(id: "dental",images: [ub,ua]))
let straight = try ArchCurve(points: [CGPoint(x: 0,y: 0),CGPoint(x: 1,y: 0)],spacing: SIMD2(0.25,0.5))
expect(straight.samples.count == 2 && abs(straight.length-0.25)<1e-9, "Arch samples use physical spacing and preserve endpoints")
expect(straight.samples[0].normal == SIMD2(0,1), "Transverse direction is perpendicular to physical arch tangent")
expect(abs(straight.imageWidth/Double(straight.samples.count)-0.25) < 1e-9,
       "Panorama image edges account for half pixels, so horizontal and vertical millimetres share the same scale")
let pano = dental.panoramic(curve: straight,thickness: 0,maximum: true,center: -624,window: 1000)!
expect(pano.width == 2 && pano.height == 2, "Panoramic dimensions")
let panoBytes = pano.dataProvider!.data! as Data
expect(panoBytes[0] > panoBytes[2], "Panoramic superior orientation")
expect(dental.dentalValue(at: SIMD2(-1,0),z: 0) == nil, "Outside-volume reformat samples must not duplicate edge anatomy")
expectThrows("Arch rejects duplicate control points") { _ = try ArchCurve(points: [.zero,.zero],spacing: SIMD2(1,1)) }
let deeper = straight.displaced(by: 0.5)
let deepPano = dental.panoramic(curve: deeper,thickness: 0,maximum: true,center: -624,window: 1000)!
let deepBytes = deepPano.dataProvider!.data! as Data
expect(deepBytes != panoBytes,"Changing panorama depth samples a different physical CT layer")
expect(deepBytes[0] == dental.displayByte(dental.patientValue(at: dental.origin+SIMD3(0,0.5,1)),center: -624,window: 1000),
       "Panorama offset is measured in millimetres along the curve normal")
let outsidePano = dental.panoramic(curve: straight.displaced(by: -0.5),thickness: 0,maximum: false,center: -624,window: 1000)!
expect((outsidePano.dataProvider!.data! as Data).allSatisfy { $0 == 0 },"Depth outside the volume displays empty pixels, never extended anatomy")
expect(dental.panoramic(curve: straight,thickness: 0,maximum: false,center: 0,window: 1000,shouldCancel: { true }) == nil,
       "Superseded depth rendering can stop before sampling CT rows")
// Exercise the asynchronous view transition, rather than only its sampling math.
let frameModel = ViewerModel(); frameModel.volume = dental; frameModel.archCurve = straight; frameModel.panoramicThickness = 0
let frameView = DentalImagesView(model: frameModel,panoramic: true)
frameView.frame = CGRect(x: 0,y: 0,width: 600,height: 300)
func awaitFrame(_ revision: Int) {
    let deadline = Date().addingTimeInterval(3)
    while frameView.imageRevision != revision && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    expect(frameView.imageRevision == revision,"Newest asynchronous panorama finishes within the test deadline")
}
frameView.refresh(); awaitFrame(frameModel.panoramicRevision)
let initialFrame = frameView.images[0], initialFrameRect = frameView.imageRect(0)
frameModel.panoramicOffset = 0.5; frameView.refresh()
expect(frameView.images.first === initialFrame && frameView.imageRect(0) == initialFrameRect && frameView.renderedCurve!.samples[0].position == .zero,
       "Pending depth retains the previous image, its physical rectangle and its overlay curve")
expect(frameView.measurementPoint(.zero) == nil,"A retained old-depth frame cannot create a measurement using the requested new depth")
for depth in [0.1,0.2,0.5] { frameModel.panoramicOffset = depth; frameView.refresh() }
expect(frameView.images.first === initialFrame,"Rapid depth requests do not insert empty frames")
awaitFrame(frameModel.panoramicRevision)
expect(frameView.renderedCurve!.samples[0].position == SIMD2(0,0.5) && (frameView.images[0].dataProvider!.data! as Data) != (initialFrame.dataProvider!.data! as Data),
       "The latest depth image and overlay geometry replace the retained frame together")
frameModel.volume = signed; frameView.refresh()
expect(frameView.images.isEmpty && frameView.renderedVolume == nil,"Changing studies clears the previous patient's image instead of retaining it")
frameModel.archCurve = nil; frameView.refresh()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
expect(frameView.images.isEmpty,"Cancelled old renders cannot refill a view after its study geometry is cleared")
let tiltedVertical = simd_normalize(SIMD3<Double>(0,1,1)), tiltedTangent = SIMD3<Double>(1,0,0)
let tiltedArch = ArchCurve(saved: XelisCurve(points: [SIMD3(0,0,2),SIMD3(3,0,2)],verticals: [tiltedVertical,tiltedVertical],
    tangents: [tiltedTangent,tiltedTangent],controls: [],frames: [],sourceRange: 0..<0),origin: .zero)
let tiltedDepth = tiltedArch.displaced(by: 2)
expect(simd_distance(tiltedDepth.localPosition(sample: tiltedDepth.samples[0],height: 3,offset: 0),
                     tiltedArch.localPosition(sample: tiltedArch.samples[0],height: 3,offset: 2)) < 1e-9,
       "Depth displacement retains the saved tilted axes and original height reference")
expect(straight.samples[0].position == .zero && tiltedArch.samples[0].sourcePosition == SIMD3(0,0,2),
       "Depth controls leave manual and imported original arch positions unchanged")

// Panoramic measurements use the developed image metric, including nonuniform saved columns.
let measurementCurve = XelisCurve(points: [SIMD3(0,0,0),SIMD3(3,0,0),SIMD3(3,4,0)],
    verticals: Array(repeating: SIMD3(0,0,1),count: 3),tangents: Array(repeating: SIMD3(1,0,0),count: 3),
    controls: [],frames: [],sourceRange: 0..<0)
let measurementArch = ArchCurve(saved: measurementCurve,origin: .zero)
expect(abs(measurementArch.distance(atColumn: 1)-3) < 1e-9,"Panoramic scale follows nonuniform original arc columns")
expect(abs(measurementArch.distance(atColumn: 1.5)-5) < 1e-9,"Subpixel distance interpolates within the saved arc segment")
expect(abs(measurementArch.column(atDistance: 5)-1.5) < 1e-9,"Physical ruler and navigation invert the column-distance map")
expect(PanoramicMeasurementGeometry.distance(.zero,CGPoint(x: 2,y: 0),curve: measurementArch,verticalSpacing: 0.5) == 7,"Panoramic horizontal length follows the developed arc, rather than the 5 mm 3D chord")
expect(PanoramicMeasurementGeometry.distance(.zero,CGPoint(x: 0,y: 8),curve: measurementArch,verticalSpacing: 0.5) == 4,"Panoramic vertical measurement uses physical voxel spacing")
expect(PanoramicMeasurementGeometry.distance(.zero,CGPoint(x: 1,y: 8),curve: measurementArch,verticalSpacing: 0.5) == 5,"Panoramic diagonal has a known 3-4-5 physical length")
for rect in [CGRect(x: 12,y: 30,width: 240,height: 100),CGRect(x: 150,y: 250,width: 720,height: 300)] {
    let a = CGPoint(x: 0,y: 2), b = CGPoint(x: 1,y: 10)
    let screenA = PanoramicMeasurementGeometry.screenPoint(a,in: rect,columns: 3,rows: 20)
    let screenB = PanoramicMeasurementGeometry.screenPoint(b,in: rect,columns: 3,rows: 20)
    let imageA = PanoramicMeasurementGeometry.imagePoint(screenA,in: rect,columns: 3,rows: 20)
    let imageB = PanoramicMeasurementGeometry.imagePoint(screenB,in: rect,columns: 3,rows: 20)
    expect(hypot(imageA.x-a.x,imageA.y-a.y) < 1e-9 && hypot(imageB.x-b.x,imageB.y-b.y) < 1e-9,"Measurement endpoints stay anchored to image pixels after resizing")
    expect(abs(PanoramicMeasurementGeometry.distance(imageA,imageB,curve: measurementArch,verticalSpacing: 0.5)-5) < 1e-9,"Panoramic length is independent of screen resolution")
    let outside = PanoramicMeasurementGeometry.imagePoint(CGPoint(x: rect.maxX+100,y: rect.minY-100),in: rect,columns: 3,rows: 20)
    expect(outside == CGPoint(x: 2,y: 0),"Dragged measurement endpoints stop at the panorama bounds")
}
let measurementModel = ViewerModel(); measurementModel.volume = dental; measurementModel.archCurve = measurementArch
let measurement = PanoramicMeasurement(start: .zero,end: CGPoint(x: 1,y: 8),mm: 5)
measurementModel.panoramicMeasurements.append(measurement)
measurementModel.setArchDistance(3); measurementModel.center = 800; measurementModel.panoramicThickness = 2
expect(measurementModel.panoramicMeasurements.count == 1,"Navigation and contrast preserve panoramic measurements")
let originalRevision = measurementModel.archRevision
measurementModel.archCurve = straight
expect(measurementModel.panoramicMeasurements.isEmpty && measurementModel.archRevision != originalRevision,"A different arch invalidates measures tied to the old geometry")
measurementModel.panoramicMeasurements.append(measurement)
let depthRevision = measurementModel.panoramicRevision, baseRevision = measurementModel.archRevision
measurementModel.movePanoramicDepth(1)
expect(measurementModel.panoramicOffset == 1 && measurementModel.panoramicRevision > depthRevision && measurementModel.archRevision == baseRevision && measurementModel.panoramicMeasurements.isEmpty,
       "Changing depth invalidates measurements from the old surface without changing the original arch")
measurementModel.movePanoramicDepth(100); expect(measurementModel.panoramicOffset == 10,"Panorama depth upper bound")
measurementModel.movePanoramicDepth(-100); expect(measurementModel.panoramicOffset == -10,"Panorama depth lower bound")
let quarterArch = ArchCurve(saved: XelisCurve(points: [SIMD3(2,0,0),SIMD3(0,2,0)],verticals: [SIMD3(0,0,1),SIMD3(0,0,1)],
    tangents: [SIMD3(0,1,0),SIMD3(-1,0,0)],controls: [],frames: [],sourceRange: 0..<0),origin: .zero)
let insetArch = quarterArch.displaced(by: 1)
expect(abs(insetArch.length-sqrt(2)) < 1e-9 && abs(quarterArch.length-2*sqrt(2)) < 1e-9,
       "Depth surface recalculates the developed measurement metric instead of reusing the base arc length")

// Canal interpolation, orthogonal review and migration from the original plan format.
let controlPoints = [SIMD3<Double>(0,0,0),SIMD3(2,3,1),SIMD3(5,2,4),SIMD3(7,4,5)]
let smoothPath = CanalPath(points: controlPoints.map(PatientPoint.init),smooth: true)
expect(smoothPath.points.count == 13, "Smooth path has bounded sampling density")
for i in controlPoints.indices { expect(simd_distance(smoothPath.points[i*4],controlPoints[i])<1e-9,"Smoothing preserves every reference point") }
for i in 0..<controlPoints.count-1 {
    let lo = simd_min(controlPoints[i],controlPoints[i+1]), hi = simd_max(controlPoints[i],controlPoints[i+1])
    for q in smoothPath.points[(i*4)...((i+1)*4)] {
        expect((0..<3).allSatisfy { q[$0] >= lo[$0]-1e-9 && q[$0] <= hi[$0]+1e-9 },"Smooth path never overshoots adjacent reference bounds")
    }
}
for d in [0.0,smoothPath.length/2,smoothPath.length] {
    let frame = smoothPath.frame(at: d)!
    expect(abs(simd_dot(frame.horizontal,frame.tangent))<1e-9 && abs(simd_dot(frame.vertical,frame.tangent))<1e-9,"Review plane is perpendicular to the path")
    expect(abs(simd_dot(frame.horizontal,frame.vertical))<1e-9 && abs(simd_length(frame.horizontal)-1)<1e-9,"Review basis preserves physical scale")
}
let verticalPath = CanalPath(points: [PatientPoint(zero),PatientPoint(SIMD3(0,0,10))],smooth: true)
expect(verticalPath.frame(at: 5)!.horizontal.x.isFinite,"Vertical canals have a stable review basis")
expect(CanalPath(points: [PatientPoint(zero),PatientPoint(zero)],smooth: true).frame(at: 0) == nil,"Repeated points do not generate an invalid review frame")
expect(abs(dental.patientValue(at: SIMD3(0.125,0.25,0.5))! - (-674))<1e-5,"Oblique sampling interpolates in all three physical axes")
expect(dental.patientValue(at: SIMD3(-0.01,0,0)) == nil,"Review does not repeat anatomy outside the volume")
let reviewFrame = CanalFrame(center: SIMD3(0.125,0.25,0.5),tangent: SIMD3(0,1,0),horizontal: SIMD3(1,0,0),vertical: SIMD3(0,0,1))
let section = dental.canalSection(frame: reviewFrame,field: 1,longitudinal: false,resolution: 3,center: -624,window: 1000)!
let sectionBytes = section.dataProvider!.data! as Data
expect(sectionBytes[1]>sectionBytes[7] && sectionBytes[0] == 0,"Oblique image keeps superior up and explicitly blanks outside voxels")
var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as! [String:Any]
legacyJSON["version"] = 1
var legacyPlanning = legacyJSON["planning"] as! [String:Any]
var legacyCanals = legacyPlanning["canals"] as! [[String:Any]]
for key in ["color","side","visible","smooth"] { legacyCanals[0].removeValue(forKey: key) }
legacyPlanning["canals"] = legacyCanals; legacyJSON["planning"] = legacyPlanning
let legacy = try JSONDecoder().decode(PlanningDocument.self,from: JSONSerialization.data(withJSONObject: legacyJSON))
try legacy.validate(for: signed)
expect(legacy.planning.canals[0].visible && !legacy.planning.canals[0].smooth && legacy.planning.canals[0].side == .unspecified,"Version 1 plans retain their original straight geometry")
var enriched = decoded
 enriched.planning.canals[0].side = .right; enriched.planning.canals[0].color = .cyan; enriched.planning.canals[0].visible = false; enriched.planning.canals[0].smooth = true
let enrichedRoundtrip = try JSONDecoder().decode(PlanningDocument.self,from: JSONEncoder().encode(enriched))
expect(enrichedRoundtrip.planning == enriched.planning,"Plan preserves side, color, visibility and smoothing")
let hit = PlanningGeometry.proximity(implant: implant,canals: [canal])!
expect(hit.canalID == canal.id && abs(hit.distanceAlong-5)<1e-9 && abs(hit.pair.distance-5)<1e-9,"Closest canal location can be reviewed reproducibly")

// Exercise actual UI model operations, including history, arbitrary points and plane-preserving drag.
let editor = ViewerModel(); editor.volume = dental; editor.reset(); editor.addCanal()
let p0 = PatientPoint(SIMD3(0,0,0)), p1 = PatientPoint(SIMD3(0.25,0.5,1)), pm = PatientPoint(SIMD3(0.125,0.25,0.5))
expect(editor.addCanalPoint(p0) && editor.addCanalPoint(p1),"Drawing appends control points")
expect(!editor.addCanalPoint(p1),"Drawing rejects an adjacent duplicate")
expect(editor.addCanalPoint(pm,after: 0) && editor.selectedCanal!.points == [p0,pm,p1],"Insert keeps path order and original endpoints")
editor.selectCanalPoint(1)
editor.moveCanalPoint(PatientPoint(SIMD3(0.2,0.4,0.9)),in: .axial)
expect(editor.selectedCanal!.points[1].z == 0.5 && editor.selectedCanal!.points[1].x == 0.2,"Dragging preserves the coordinate normal to the displayed slice")
editor.undoCanalEdit(); expect(editor.selectedCanal!.points[1] == pm,"Undo restores an arbitrary moved point")
editor.redoCanalEdit(); expect(editor.selectedCanal!.points[1].x == 0.2,"Redo restores the edit")
editor.selectCanalPoint(1); editor.deleteCanalPoint()
expect(editor.selectedCanal!.points == [p0,p1],"Delete removes only the selected middle point")
editor.undoCanalEdit(); expect(editor.selectedCanal!.points.count == 3,"Undo restores deleted control points")
editor.updateCanal(\.name,value: "Derecho revisado"); editor.updateCanal(\.visible,value: false)
editor.undoCanalEdit(); expect(editor.selectedCanal!.visible && editor.selectedCanal!.name == "Derecho revisado","Visibility participates in history independently of naming")
editor.selectCanalPoint(0); editor.updateCanalCoordinate(0,value: -999)
expect(editor.selectedCanal!.points[0].x == dental.origin.x,"Coordinate edits stay inside the acquired volume")
editor.selectCanalPoint(1); editor.updateCanal(\.smooth,value: true)
expect(abs(editor.reviewDistance-editor.selectedCanal!.path.distances[4])<1e-9,"Changing smoothing keeps review centered on the selected reference")
let canalID = editor.selectedCanalID
editor.removeCanal(); expect(editor.planning.canals.isEmpty,"Canal removal updates the plan")
editor.undoCanalEdit(); expect(editor.selectedCanalID == canalID,"Undo recovers a deleted canal and its identity")
if let metalDevice = MTLCreateSystemDefaultDevice() {
    _ = try metalDevice.makeLibrary(source: VolumeMetalView.shader,options: nil)
    expect(true,"Native volume shader compiles")
} else { print("Metal unavailable in CLI sandbox; verify native app rendering separately.") }
if CommandLine.arguments.count > 1 {
    let scan = try StudyLoader.scan(URL(fileURLWithPath: CommandLine.arguments[1]))
    expect(!scan.series.isEmpty, "Private study has a compatible CT series")
    expect(scan.compressedFiles == 0 && !scan.xelisProjects.isEmpty && scan.projectFiles > 0 && scan.failures.isEmpty, "Sample project compatibility report")
    let start = Date()
    let v = try CTVolume(series: scan.series[0])
    expect(v.width > 0 && v.height > 0 && v.depth == scan.series[0].images.count, "Imported dimensions match the selected series")
    expect(v.spacing.x > 0 && v.spacing.y > 0 && v.spacing.z > 0, "Imported physical spacing is positive")
    let sourceProject = scan.xelisProjects[0]
    expect(sourceProject.pixels == nil && sourceProject.string(0x75730010) == "MEVISYS","Compressed project preview retains private data without JPEG decoding")
    let project = try XelisProject.load(sourceProject,volume: v)
    expect(!project.canals.isEmpty && project.canals.allSatisfy { !$0.points.isEmpty && !$0.controls.isEmpty }, "Import original canal samples and controls")
    expect(!project.arch.points.isEmpty && !project.arch.controls.isEmpty, "Import the original dental arch")
    let calibratedArch = ArchCurve(saved: project.arch,origin: v.origin)
    // Regression for resize crashes: run the drawing code with the original canal
    // overlays while the native image views temporarily have almost no space.
    let resizeModel = ViewerModel(); resizeModel.volume = v; resizeModel.archCurve = calibratedArch; resizeModel.xelisProject = project
    let resizeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 64,pixelsHigh: 64,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resizeBitmap)
    for panoramic in [true,false] {
        let resizeView = DentalImagesView(model: resizeModel,panoramic: panoramic)
        resizeView.renderedVolume = v; resizeView.renderedCurve = calibratedArch; resizeView.renderedArchCurve = calibratedArch
        resizeView.images = Array(repeating: pano,count: panoramic ? 1 : 9)
        resizeView.indices = resizeModel.transverseIndices(calibratedArch)
        for size in [CGSize.zero,CGSize(width: 1,height: 1),CGSize(width: 10,height: 300),CGSize(width: 600,height: 10)] {
            resizeView.frame = CGRect(origin: .zero,size: size)
            expect(resizeView.images.indices.allSatisfy { resizeView.imageRect($0) == .zero },
                   "Tiny \(panoramic ? "panoramic" : "transverse") views have no invalid image rectangle")
            resizeView.draw(resizeView.bounds)
            resizeView.drawXelisCanals(in: .zero,cell: 0)
            resizeView.drawXelisCanals(in: .null,cell: 0)
        }
        resizeView.frame = CGRect(x: 0,y: 0,width: 600,height: 300)
        expect(resizeView.imageRect(0).width > 0 && resizeView.imageRect(0).height > 0,"Original images recover drawable dimensions after a tiny layout")
        resizeView.draw(resizeView.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    // Exercise the same interaction entry points used by mouse events in Dental.
    // Check physical placement against the saved 3D frames, not just tool selection.
    for panoramic in [false,true] {
        let interactionModel = ViewerModel(); interactionModel.volume = v; interactionModel.xelisProject = project
        interactionModel.archCurve = calibratedArch; interactionModel.setArchDistance(27.5); interactionModel.z = 213
        if !panoramic { interactionModel.enlargedTransverseIndex = 4 }
        let view = DentalImagesView(model: interactionModel,panoramic: panoramic)
        view.frame = CGRect(x: 0,y: 0,width: 600,height: 600)
        view.renderedVolume = v; view.previousVolume = v; view.renderedCurve = calibratedArch; view.renderedArchCurve = calibratedArch
        view.renderedField = 25; view.imageRevision = view.geometryRevision
        view.indices = interactionModel.transverseIndices(calibratedArch)
        let cell = panoramic ? 0 : 4
        let image = panoramic ? v.panoramic(curve: calibratedArch,thickness: 0,maximum: false,center: 1024,window: 4096)!
            : v.transverse(curve: calibratedArch,index: view.indices[cell],field: 25,center: 1024,window: 4096)!
        view.images = Array(repeating: image,count: panoramic ? 1 : 9)
        let a = panoramic ? CGPoint(x: 250,y: 100) : CGPoint(x: 0,y: 34)
        let b = panoramic ? CGPoint(x: 270,y: 120) : CGPoint(x: 3,y: 38)
        let screenA = view.dentalScreenPoint(a,cell: cell), screenB = view.dentalScreenPoint(b,cell: cell)
        expect(view.interactionCell(at: screenA) == cell && view.interactionCell(at: screenB) == cell,"Dental input targets the displayed image, including an enlarged section")
        let mapped = view.dentalImagePoint(screenA,cell: cell)!
        expect(hypot(mapped.x-a.x,mapped.y-a.y) < 1e-8,"Dental screen coordinates round trip to physical measurement coordinates")
        interactionModel.selectTool(.measure)
        view.beginDentalInteraction(at: screenA); view.dragDentalInteraction(to: screenB); view.endDentalInteraction(at: screenB)
        if panoramic {
            expect(interactionModel.panoramicMeasurements.count == 1 && interactionModel.panoramicMeasurements[0].mm > 4,"Medir creates a panorama measurement through the Dental input handlers")
        } else {
            expect(interactionModel.transverseMeasurements.count == 1 && abs(interactionModel.transverseMeasurements[0].mm-5) < 1e-4,"Medir creates a physical 3-4-5 mm transverse ruler on a saved tilted frame")
        }
        interactionModel.selectTool(.window); interactionModel.center = 1024; interactionModel.window = 4096
        view.beginDentalInteraction(at: screenA)
        view.dragDentalInteraction(to: CGPoint(x: screenA.x+20,y: screenA.y+10)); view.refresh()
        view.dragDentalInteraction(to: CGPoint(x: screenA.x+30,y: screenA.y+20)); view.endDentalInteraction(at: screenA)
        expect(interactionModel.center == 924 && interactionModel.window == 4396,"Contraste keeps its drag anchor when SwiftUI refreshes the reformat")
        interactionModel.showPlanning = false; interactionModel.selectTool(.implant)
        let expectedEntry = view.dentalPatientPoint(a,cell: cell)!
        view.beginDentalInteraction(at: screenA); view.endDentalInteraction(at: screenA)
        expect(interactionModel.showPlanning && interactionModel.planning.implants.count == 1 && simd_distance(interactionModel.selectedImplant!.entry.vector,expectedEntry) < 1e-8,"Implante becomes visible and is placed at the saved reformat's actual patient position")
        view.beginDentalInteraction(at: screenA); view.dragDentalInteraction(to: screenB); view.endDentalInteraction(at: screenB)
        expect(interactionModel.planning.implants.count == 1 && simd_distance(interactionModel.selectedImplant!.entry.vector,view.dentalPatientPoint(b,cell: cell)!) < 1e-8,"Dragging an implant moves the selected one without creating duplicates")
        interactionModel.selectTool(.canal)
        view.beginDentalInteraction(at: screenA); view.endDentalInteraction(at: screenA)
        view.beginDentalInteraction(at: screenB); view.endDentalInteraction(at: screenB)
        expect(interactionModel.selectedCanal?.points.count == 2,"Canal creates a manual trace from two Dental image clicks")
        expect(simd_distance(interactionModel.selectedCanal!.points[0].vector,expectedEntry) < 1e-8,"Dental canal coordinates use the displayed saved surface, without anatomical inference")
        expect(view.dentalCanalHit(at: screenA,cell: cell,segments: false)?.1 == 0,"Manual canal controls can be selected through their Dental image projection")
        interactionModel.canalInteraction = .edit
        let third = panoramic ? CGPoint(x: 280,y: 130) : CGPoint(x: 4,y: 39)
        let screenC = view.dentalScreenPoint(third,cell: cell)
        view.beginDentalInteraction(at: screenB); view.dragDentalInteraction(to: screenC); view.endDentalInteraction(at: screenC)
        expect(simd_distance(interactionModel.selectedCanal!.points[1].vector,view.dentalPatientPoint(third,cell: cell)!) < 1e-7,"Manual canal points move in the selected reformat while retaining the transverse plane coordinate")
        interactionModel.undoCanalEdit()
        expect(simd_distance(interactionModel.selectedCanal!.points[1].vector,view.dentalPatientPoint(b,cell: cell)!) < 1e-7,"A Dental canal drag is one reversible editing action")
        interactionModel.selectTool(.navigate)
        view.beginDentalInteraction(at: screenA); view.endDentalInteraction(at: screenA)
        expect(simd_distance(interactionModel.referencePoint!.vector,expectedEntry) < 1e-8,"Navegar synchronizes axial/MPR to the actual patient position of a Dental image click")
        let currentTool = interactionModel.tool; interactionModel.selectTool(.arch)
        expect(interactionModel.tool == currentTool && interactionModel.xelisProject!.arch.points == project.arch.points,"Protected original curve cannot silently enter a nonfunctional edit mode")
        let oldCount = interactionModel.planning.implants.count
        interactionModel.selectTool(.implant); interactionModel.panoramicOffset = 0.1
        if panoramic { view.beginDentalInteraction(at: screenA); expect(interactionModel.planning.implants.count == oldCount && view.dragTool == nil,"Pending depth cannot place an implant using a retained old surface") }
    }
    let independentLength = zip(project.arch.points, project.arch.points.dropFirst()).reduce(0.0) { $0 + simd_distance($1.0,$1.1) }
    expect(abs(calibratedArch.length-independentLength) < 1e-8, "Imported arc retains the original polyline length in millimetres")
    let archive = sourceProject.values[0x75731004]!
    let payload = try XelisProject.unzip(archive)
    expect(!payload.isEmpty,"Native zlib extracts the saved snapshot")
    var wrongVersion = payload; wrongVersion[0] = 0
    expectThrows("Unknown snapshots must fail without estimating anatomy") { _ = try XelisProject.decode(wrongVersion) }
    expectThrows("Truncated saved snapshot must fail") { _ = try XelisProject.decode(payload.prefix(10000)) }
    var corruptCRC = archive; corruptCRC[14] ^= 1
    expectThrows("Corrupt project ZIP rejected") { _ = try XelisProject.unzip(corruptCRC) }
    expectThrows("Truncated project ZIP rejected") { _ = try XelisProject.unzip(archive.prefix(100)) }
    var otherTags = sourceProject.values; otherTags[0x0020000D] = Data("other-study".utf8)
    let otherStudy = DICOMImage(url: sourceProject.url,data: sourceProject.data,values: otherTags,pixels: nil,syntax: sourceProject.syntax)
    expectThrows("Canal from another study must be rejected") { _ = try XelisProject.load(otherStudy,volume: v) }
    var otherRefs = sourceProject.values[0x75731003]!; otherRefs[1072] = 49
    otherTags = sourceProject.values; otherTags[0x75731003] = otherRefs
    let otherSeries = DICOMImage(url: sourceProject.url,data: sourceProject.data,values: otherTags,pixels: nil,syntax: sourceProject.syntax)
    expectThrows("Different source SOP instance must be rejected") { _ = try XelisProject.load(otherSeries,volume: v) }
    let importedModel = ViewerModel(); importedModel.volume = v; importedModel.xelisProject = project; importedModel.initializeDentalCurve()
    expect(importedModel.archCurve!.samples.count == project.arch.points.count && importedModel.transverseIndices(importedModel.archCurve!).count == 9,"Dental workspace retains saved arch and nine sections")
    importedModel.focusXelisCanal()
    expect(importedModel.z >= 0 && importedModel.z < Double(v.depth),"Focus stays inside the imported volume")
    importedModel.sourceCanalIndex = 1; importedModel.reviewOriginalCanal()
    expect(importedModel.reviewedCanal!.points.map(\.vector) == project.canals[1].points,"Review uses exact original positions independently of manual planning")
    expect(importedModel.planning.canals.isEmpty && importedModel.reviewCanal,"Reading original canals does not create an inferred or manual plan")
    expect(simd_distance(v.origin+SIMD3(importedModel.x,importedModel.y,importedModel.z)*v.spacing,project.canals[1].points[0]) < 1e-10,"Original review synchronizes source DICOM reference")
    importedModel.reviewDistance = 15
    importedModel.sourceCanalIndex = 0
    expect(importedModel.reviewSourceIndex == 0 && importedModel.reviewedCanal!.points.map(\.vector) == project.canals[0].points,
           "Changing the original canal picker updates the active review immediately")
    expect(importedModel.reviewDistance == 0 && simd_distance(v.origin+SIMD3(importedModel.x,importedModel.y,importedModel.z)*v.spacing,project.canals[0].points[0]) < 1e-10,
           "Switching review resets distance and synchronizes the corresponding original canal")
    importedModel.reviewCanal = false; importedModel.sourceCanalIndex = 1
    let focused = v.origin+SIMD3(importedModel.x,importedModel.y,importedModel.z)*v.spacing
    expect(simd_distance(focused,project.canals[1].controls[1]) < simd_length(v.spacing),
           "Changing the picker outside review focuses the other actual canal, without an extra button click")
    expect(project.canals[0].points != project.canals[1].points,"Original canal records retain distinct paths")
    let vertices = XelisOverlayGeometry.vertices(project: project,volume: v)
    expect(vertices.count == project.canals.reduce(0) { $0 + ($1.points.count-1)*8*6 },"GPU overlay preserves every source canal segment beyond manual planning limit")
    expect(vertices.allSatisfy { $0.position.x.isFinite && $0.normal.x.isFinite },"Saved canal display geometry stays finite")
    let clipped = XelisOverlayGeometry.clipped(SIMD3(0,0,-2),SIMD3(0,0,2),center: .zero,normal: SIMD3(0,0,1),halfWidth: 0.5)!
    expect(clipped.0.z == -0.5 && clipped.1.z == 0.5,"Slice overlay clips original coordinates to the displayed plane")
    print(String(format: "Sample loaded and 3 planes rendered in %.2fs", Date().timeIntervalSince(start)))
}
print("PASS: \(checks) checks")
