import Foundation
import AppKit
import simd
import CryptoKit

// Mathematical calibration fixtures. These contain no data copied from a study.
struct CalibrationProfile {
    let bits: Int, stored: Int, signed: Bool, implicit: Bool, inverted: Bool
    let spacing: SIMD3<Double>, origin: SIMD3<Double>, slope: Double, intercept: Double
    func raw(x: Double, y: Double, z: Double) -> Double { (signed ? -80 : 20)+x+2*y+3*z }
    func value(x: Double, y: Double, z: Double) -> Double { raw(x: x,y: y,z: z)*slope+intercept }
}
func calibrationSlice(_ profile: CalibrationProfile, z: Int, width: Int, height: Int) -> Data {
    var data = Data(repeating: 0,count: 128)+Data("DICM".utf8)
    data += element(0x00020010,"UI",Data((profile.implicit ? "1.2.840.10008.1.2" : "1.2.840.10008.1.2.1").utf8))
    func add(_ key: UInt32, _ vr: String, _ bytes: Data) { data += element(key,vr,bytes,implicit: profile.implicit) }
    func text(_ key: UInt32, _ vr: String, _ value: String) { add(key,vr,Data(value.utf8)) }
    text(0x00080016,"UI","1.2.840.10008.5.1.4.1.1.2")
    text(0x00080018,"UI","1.2.3.10.\(z+1)")
    text(0x0020000D,"UI","1.2.3.10"); text(0x0020000E,"UI","1.2.3.10.1")
    text(0x00100010,"PN","SYNTHETIC^CALIBRATION")
    text(0x00200032,"DS","\(profile.origin.x)\\\(profile.origin.y)\\\(profile.origin.z+Double(z)*profile.spacing.z)")
    text(0x00200037,"DS","1\\0\\0\\0\\1\\0")
    text(0x00280030,"DS","\(profile.spacing.y)\\\(profile.spacing.x)")
    text(0x00280004,"CS",profile.inverted ? "MONOCHROME1" : "MONOCHROME2")
    for (key,value): (UInt32,Int) in [(0x00280002,1),(0x00280010,height),(0x00280011,width),
        (0x00280100,profile.bits),(0x00280101,profile.stored),(0x00280102,profile.stored-1),(0x00280103,profile.signed ? 1 : 0)] {
        add(key,"US",le16(UInt16(value)))
    }
    text(0x00281052,"DS","\(profile.intercept)"); text(0x00281053,"DS","\(profile.slope)")
    var pixels = Data()
    for y in 0..<height {
        for x in 0..<width {
            var raw = UInt16(truncatingIfNeeded: Int(profile.raw(x: Double(x),y: Double(y),z: Double(z))))
            raw &= UInt16(truncatingIfNeeded: (1 << profile.stored)-1)
            if profile.stored == 12 { raw |= 0xA000 } // Unused bits must not affect signed decoding.
            if profile.bits == 8 { pixels.append(UInt8(truncatingIfNeeded: raw)) } else { pixels += le16(raw) }
        }
    }
    add(0x7FE00010,profile.bits == 8 ? "OB" : "OW",pixels)
    return data
}
func calibrationGray(_ value: Double, center: Double, window: Double, inverted: Bool) -> UInt8 {
    // DICOM PS3.3 C.11.2: piecewise linear window and width=1 threshold.
    let low = center-0.5-(window-1)/2, high = center-0.5+(window-1)/2
    let normalized: Double
    if value <= low { normalized = 0 }
    else if value > high { normalized = 1 }
    else { normalized = (value-low)/(high-low) }
    return UInt8((inverted ? 1-normalized : normalized)*255)
}
func runTechnicalValidation() throws {
    let profiles = [
        CalibrationProfile(bits: 16,stored: 16,signed: false,implicit: false,inverted: false,spacing: SIMD3(0.25,0.5,1),origin: .zero,slope: 1,intercept: -1024),
        CalibrationProfile(bits: 16,stored: 12,signed: true,implicit: false,inverted: false,spacing: SIMD3(0.5,0.75,1.25),origin: SIMD3(-12.5,35.25,-7.5),slope: 2,intercept: 10),
        CalibrationProfile(bits: 16,stored: 16,signed: true,implicit: true,inverted: false,spacing: SIMD3(0.2,0.4,0.8),origin: SIMD3(3,-8,11),slope: 0.5,intercept: -100),
        CalibrationProfile(bits: 16,stored: 12,signed: false,implicit: true,inverted: true,spacing: SIMD3(0.5,0.75,1.25),origin: SIMD3(-12.5,35.25,-7.5),slope: -0.5,intercept: 100),
        CalibrationProfile(bits: 8,stored: 8,signed: false,implicit: false,inverted: false,spacing: SIMD3(0.25,0.5,1),origin: SIMD3(3,-8,11),slope: 1,intercept: 0),
        CalibrationProfile(bits: 8,stored: 8,signed: true,implicit: true,inverted: true,spacing: SIMD3(0.5,0.75,1.25),origin: SIMD3(-12.5,35.25,-7.5),slope: 2,intercept: 10)
    ]
    let width = 31, height = 29, depth = 25
    var voxelCount = 0, renderedPixelCount = 0, interpolationCount = 0, measurementCount = 0
    var maxVoxelError = 0.0, maxInterpolationError = 0.0, maxMeasurementError = 0.0, maxGrayError = 0
    var calibrationVolume: CTVolume?
    for (profileIndex,profile) in profiles.enumerated() {
        let folder = URL(fileURLWithPath: "output/test-fixtures/calibration-\(profileIndex)")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        var slices: [DICOMImage] = []
        for z in 0..<depth {
            let url = folder.appendingPathComponent("slice-\(z).dcm")
            try calibrationSlice(profile,z: z,width: width,height: height).write(to: url)
            guard let parsed = try DICOMReader.read(url) else { throw ViewerError.message("Calibration DICOM not parsed") }
            slices.append(parsed)
        }
        let v = try CTVolume(series: DICOMSeries(id: "calibration",images: slices.reversed()))
        if profileIndex == 1 { calibrationVolume = v }
        expect(v.width == width && v.height == height && v.depth == depth,"Calibration volume keeps dimensions after reversed file order")
        expect(simd_distance(v.origin,profile.origin) < 1e-10 && simd_distance(v.spacing,profile.spacing) < 1e-10,"Calibration keeps DICOM origin and anisotropic row/column/slice spacing")
        var voxelError = 0.0
        for z in 0..<depth { for y in 0..<height { for x in 0..<width {
            voxelError = max(voxelError,abs(Double(v.value(x: x,y: y,z: z))-profile.value(x: Double(x),y: Double(y),z: Double(z))))
            voxelCount += 1
        } } }
        maxVoxelError = max(maxVoxelError,voxelError)
        expect(voxelError == 0,"Every calibration voxel matches its known signed/unsigned ramp and intensity rescale")
        if profile.bits == 8 {
            let first = slices[0]
            var paddedData = first.data
            paddedData[first.pixels!.upperBound-1] = 0xFD
            let padded = DICOMImage(url: first.url,data: paddedData,values: first.values,pixels: first.pixels,syntax: first.syntax)
            let paddedVolume = try CTVolume(series: DICOMSeries(id: "padded-calibration",images: [padded]+Array(slices.dropFirst())))
            expect(paddedVolume.voxels == v.voxels,"An odd native pixel count ignores the final padding byte regardless of its value")
            for extra in [-1,1] {
                let range = first.pixels!.lowerBound..<first.pixels!.upperBound+extra
                let malformed = DICOMImage(url: first.url,data: first.data,values: first.values,pixels: range,syntax: first.syntax)
                expectThrows("Missing or excess native pixel padding must reject the series") {
                    _ = try CTVolume(series: DICOMSeries(id: "invalid-padding",images: [malformed]+Array(slices.dropFirst())))
                }
            }
        }
        for plane in Plane.allCases {
            let (w,h,sx,sy) = v.dimensions(plane)
            let number = plane == .axial ? depth : plane == .coronal ? height : width
            var grayError = 0
            let center = profile.value(x: 15,y: 14,z: 12), window = 256.0
            for index in 0..<number {
                let bitmap = v.slice(plane,index: index,center: center,window: window)!
                let bytes = bitmap.dataProvider!.data! as Data
                for row in 0..<h { for column in 0..<w {
                    let x = plane == .sagittal ? index : column
                    let y = plane == .axial ? row : plane == .coronal ? index : column
                    let z = plane == .axial ? index : depth-1-row
                    let expected = calibrationGray(profile.value(x: Double(x),y: Double(y),z: Double(z)),center: center,window: window,inverted: profile.inverted)
                    grayError = max(grayError,abs(Int(bytes[row*w+column])-Int(expected))); renderedPixelCount += 1
                } }
            }
            maxGrayError = max(maxGrayError,grayError)
            expect(grayError <= 1,"Every MPR pixel has the expected physical axis, superior orientation and DICOM contrast")
            let model = ViewerModel(); model.volume = v; model.x = 11; model.y = 12; model.z = 13
            let view = SliceView(model: model,plane: plane)
            let a = CGPoint(x: 2,y: 3), b = CGPoint(x: 2+3/sx,y: 3+4/sy)
            for size in [CGSize(width: 320,height: 240),CGSize(width: 1180,height: 820)] {
                view.frame = CGRect(origin: .zero,size: size)
                for zoom in [0.7,1.0,2.4] {
                    view.zoom = zoom; view.pan = CGPoint(x: 37,y: -21)
                    let screenA = view.screenPoint(a), screenB = view.screenPoint(b)
                    let mappedA = view.imagePoint(screenA), mappedB = view.imagePoint(screenB)
                    let measured = view.distance(mappedA,mappedB)
                    maxMeasurementError = max(maxMeasurementError,abs(measured-5)); measurementCount += 1
                    expect(abs(measured-5) < 1e-9,"Known 3-4-5 mm MPR measurement survives resize, zoom and pan")
                    let p = model.patientPoint(plane,imagePoint: mappedA)!.vector, q = model.patientPoint(plane,imagePoint: mappedB)!.vector
                    expect(abs(simd_distance(p,q)-5) < 1e-9,"MPR point placement has the same physical metric as its ruler")
                    let screenHorizontal = abs(screenB.x-screenA.x), screenVertical = abs(screenB.y-screenA.y)
                    expect(abs(screenHorizontal/screenVertical-0.75) < 1e-10,"Three horizontal millimetres and four vertical millimetres share a display scale")
                }
            }
        }
        var interpolationError = 0.0
        for i in 0..<40 {
            let q = SIMD3(Double((i*7)%27)+0.25,Double((i*11)%25)+0.5,Double((i*13)%21)+0.75)
            let p = profile.origin+q*profile.spacing
            interpolationError = max(interpolationError,abs(Double(v.patientValue(at: p)!)-profile.value(x: q.x,y: q.y,z: q.z)))
            interpolationCount += 1
        }
        maxInterpolationError = max(maxInterpolationError,interpolationError)
        expect(interpolationError < 0.0001,"Trilinear sampling agrees with a known continuous field in physical coordinates")
        expect(v.patientValue(at: v.origin-SIMD3(0.001,0,0)) == nil && v.patientValue(at: SIMD3(.nan,0,0)) == nil,"Outside and nonfinite positions cannot extend the calibration volume")
        for window in [1.0,2.0,256.0] {
            for value in [-1200.0,-80,-0.5,0,0.5,1,30,1024] {
                let expected = calibrationGray(value,center: 0,window: window,inverted: profile.inverted)
                expect(abs(Int(v.displayByte(Float(value),center: 0,window: window))-Int(expected)) <= 1,"DICOM width-one threshold, clipping and inversion are correct")
            }
        }
        var invalid = slices[0].values
        for (key,text) in [(UInt32(0x00280030),"NaN\\0.5"),(0x00200032,"0\\0\\Infinity"),(0x00281053,"NaN"),(0x00280030,"0\\0.5"),(0x00200037,"0\\1\\0\\1\\0\\0")] {
            invalid = slices[0].values; invalid[key] = Data(text.utf8)
            let corrupt = DICOMImage(url: slices[0].url,data: slices[0].data,values: invalid,pixels: slices[0].pixels,syntax: slices[0].syntax)
            expectThrows("Invalid spacing, position, intensity or orientation must reject the calibration series") {
                _ = try CTVolume(series: DICOMSeries(id: "invalid-calibration",images: [corrupt]+Array(slices.dropFirst())))
            }
        }
    }
    let v = calibrationVolume!
    var transverseScaleError = 0.0
    for degrees in [0.0,25.0,60.0] {
        let angle = degrees * .pi/180, vertical = SIMD3<Double>(0,sin(angle),cos(angle)), tangent = SIMD3<Double>(1,0,0)
        let saved = XelisCurve(points: [v.origin+SIMD3(4,4,3),v.origin+SIMD3(7,4,3)],verticals: [vertical,vertical],tangents: [tangent,tangent],controls: [],frames: [],sourceRange: 0..<0)
        let arch = ArchCurve(saved: saved,origin: v.origin)
        let model = ViewerModel(); model.volume = v; model.archCurve = arch; model.z = 10; model.tool = .measure
        let view = DentalImagesView(model: model,panoramic: false)
        view.renderedVolume = v; view.previousVolume = v; view.renderedCurve = arch; view.renderedArchCurve = arch
        view.renderedField = 6; view.indices = Array(repeating: 0,count: 9); view.imageRevision = view.geometryRevision
        let bitmap = v.transverse(curve: arch,index: 0,field: 6,center: 0,window: 500)!
        view.images = Array(repeating: bitmap,count: 9)
        let a = CGPoint(x: -1,y: 10.5), b = CGPoint(x: 2,y: 14.5)
        for enlarged in [false,true] {
            model.enlargedTransverseIndex = enlarged ? 4 : nil
            for size in [CGSize(width: 600,height: 600),CGSize(width: 1200,height: 900)] {
                view.frame = CGRect(origin: .zero,size: size)
                let screenA = view.dentalScreenPoint(a,cell: 4), screenB = view.dentalScreenPoint(b,cell: 4)
                let mappedA = view.dentalImagePoint(screenA,cell: 4)!, mappedB = view.dentalImagePoint(screenB,cell: 4)!
                expect(view.interactionCell(at: screenA) == 4 && view.interactionCell(at: screenB) == 4,"Calibration clicks stay in their displayed transverse section")
                let mm = simd_distance(view.dentalPatientPoint(mappedA,cell: 4)!,view.dentalPatientPoint(mappedB,cell: 4)!)
                maxMeasurementError = max(maxMeasurementError,abs(mm-5)); measurementCount += 1
                expect(abs(mm-5) < 1e-9,"A tilted transverse plane retains a known 3-4-5 mm measurement")
                let ratio = abs((screenB.x-screenA.x)/(screenB.y-screenA.y))
                transverseScaleError = max(transverseScaleError,abs(ratio-0.75))
                expect(abs(ratio-0.75) < 1e-10,"Transverse pixel edges give horizontal and vertical millimetres the same display scale")
                view.beginDentalInteraction(at: screenA); view.dragDentalInteraction(to: screenB); view.endDentalInteraction(at: screenB)
                expect(abs(model.transverseMeasurements.last!.mm-5) < 1e-9,"Actual transverse input handlers store the known calibration distance")
            }
        }
    }
    let circleCount = 65, radius = 20.0
    let positions = (0..<circleCount).map { i -> SIMD3<Double> in let angle = Double(i)*Double.pi/Double(circleCount-1); return SIMD3(radius*cos(angle),radius*sin(angle),10) }
    let tangents = (0..<circleCount).map { i -> SIMD3<Double> in let angle = Double(i)*Double.pi/Double(circleCount-1); return SIMD3(-sin(angle),cos(angle),0) }
    let circle = ArchCurve(saved: XelisCurve(points: positions,verticals: Array(repeating: SIMD3(0,0,1),count: circleCount),tangents: tangents,controls: [],frames: [],sourceRange: 0..<0),origin: .zero)
    var circleLengthError = 0.0
    for offset in [-10.0,-3,0,2,10] {
        let displaced = circle.displaced(by: offset)
        let expected = 2*(radius-offset)*Double(circleCount-1)*sin(.pi/(2*Double(circleCount-1)))
        circleLengthError = max(circleLengthError,abs(displaced.length-expected))
        expect(abs(displaced.length-expected) < 1e-9,"Known circular arch length changes with physical panoramic depth")
        let a = CGPoint(x: 0,y: 2), b = CGPoint(x: circleCount-1,y: 18)
        let mm = PanoramicMeasurementGeometry.distance(a,b,curve: displaced,verticalSpacing: 0.25)
        expect(abs(mm-hypot(expected,4)) < 1e-9,"Panoramic diagonal uses developed arc length and known vertical spacing")
        measurementCount += 1; maxMeasurementError = max(maxMeasurementError,abs(mm-hypot(expected,4)))
    }
    let duplicate = ArchCurve(saved: XelisCurve(points: [SIMD3(0,0,0),SIMD3(3,0,0),SIMD3(3,4,0),SIMD3(3,4,0),SIMD3(9,4,0)],verticals: Array(repeating: SIMD3(0,0,1),count: 5),tangents: Array(repeating: SIMD3(1,0,0),count: 5),controls: [],frames: [],sourceRange: 0..<0),origin: .zero)
    for distance in [0.0,1.5,3,5,7,10,13] {
        expect(abs(duplicate.distance(atColumn: duplicate.column(atDistance: distance))-distance) < 1e-10,"Physical ruler remains invertible through irregular and duplicate columns")
    }
    let summary: [String:Any] = ["status":"pass", "synthetic_profiles":profiles.count,"known_voxels_checked":voxelCount,
        "mpr_pixels_checked":renderedPixelCount,"continuous_field_samples":interpolationCount,"known_measurements_checked":measurementCount,
        "maximum_voxel_intensity_error":maxVoxelError,"maximum_interpolation_intensity_error":maxInterpolationError,
        "maximum_gray_difference_levels":maxGrayError,"maximum_distance_error_mm":maxMeasurementError,
        "maximum_transverse_display_ratio_error":transverseScaleError,"maximum_circular_arc_length_error_mm":circleLengthError,
        "scope":"Mathematical fixtures and application input handlers; not a physical phantom or clinical study."]
    let report = try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys])
    try report.write(to: URL(fileURLWithPath: "output/technical-validation-synthetic.json"))
    print("Calibration PASS: \(profiles.count) profiles, \(voxelCount) voxels, \(renderedPixelCount) MPR pixels, \(measurementCount) known measurements")
}

// Contains original coordinates and must stay under ignored output/.
func writePrivateValidationReference(volume: CTVolume, project: XelisProject, sourceProject: DICOMImage) throws {
    func vector(_ p: SIMD3<Double>) -> [Double] { [p.x,p.y,p.z] }
    func curve(_ c: XelisCurve) -> [String:Any] {
        ["points":c.points.map(vector),"controls":c.controls.map(vector),"verticals":c.verticals.map(vector),"tangents":c.tangents.map(vector),
         "frames":c.frames.map { ["point":vector($0.point),"vertical":vector($0.vertical),"tangent":vector($0.tangent),"distance":$0.distance] as [String:Any] }]
    }
    var samples: [[String:Any]] = []
    for z in [0,volume.depth/4,volume.depth/2,3*volume.depth/4,volume.depth-1] {
        for y in [0,volume.height/3,volume.height/2,volume.height-1] {
            for x in [0,volume.width/3,volume.width/2,volume.width-1] {
                samples.append(["voxel":[x,y,z],"value":Double(volume.value(x: x,y: y,z: z))])
            }
        }
    }
    var byteSums: [UInt64] = [], byteHashes: [String] = []
    for z in 0..<volume.depth {
        let start = z*volume.width*volume.height
        byteSums.append(volume.voxels[start..<start+volume.width*volume.height].reduce(UInt64(0)) { $0+UInt64($1) })
        let slice = Array(volume.voxels[start..<start+volume.width*volume.height])
        let hash = slice.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        byteHashes.append(hash.map { String(format: "%02x",$0) }.joined())
    }
    let arch = ArchCurve(saved: project.arch,origin: volume.origin)
    let report: [String:Any] = ["dimensions":[volume.width,volume.height,volume.depth],"origin":vector(volume.origin),"spacing":vector(volume.spacing),
        "study_uid":volume.studyUID,"series_uid":volume.seriesUID,"source_sop_uids":volume.sourceSOPUIDs.sorted(),
        "source_project_path":sourceProject.url.path,"slice_raw_sums":byteSums,"slice_raw_sha256":byteHashes,"intensity_samples":samples,
        "arch":curve(project.arch),"canals":project.canals.map(curve),"arch_length_mm":arch.length]
    try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: "output/technical-validation-private-reference.json"))
}
