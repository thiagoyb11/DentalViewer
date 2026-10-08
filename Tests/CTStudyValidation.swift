import Foundation
import AppKit
import simd

// Real CT integration checks. The physical dimensions of an object must be
// supplied separately; DICOM spacing is not a manufacturing ground truth.
func runCTStudyValidation(_ folder: URL) throws {
    let scan = try StudyLoader.scan(folder)
    expect(scan.compressedFiles == 0 && scan.failures.isEmpty,"CT reference study contains compatible native DICOM images")
    let volume = try CTVolume(series: scan.series[0])
    expect(volume.depth == scan.series[0].images.count,"CT reference importer keeps every source slice")
    let model = ViewerModel(); model.volume = volume
    model.x = Double(volume.width/2); model.y = Double(volume.height/2); model.z = Double(volume.depth/2)
    var maximumDistanceError = 0.0, distances = 0, pixelsChecked = 0
    for plane in Plane.allCases {
        let (width,height,sx,sy) = volume.dimensions(plane)
        let count = plane == .axial ? volume.depth : plane == .coronal ? volume.height : volume.width
        for index in [0,count/2,count-1] {
            let image = volume.slice(plane,index: index,center: 0,window: 1600)!
            expect(image.width == width && image.height == height,"CT reference MPR keeps its expected pixel dimensions")
            let bytes = image.dataProvider!.data! as Data
            var grayDifference = 0
            for row in stride(from: 0,to: height,by: max(1,height/17)) {
                for column in stride(from: 0,to: width,by: max(1,width/19)) {
                    let x = plane == .sagittal ? index : column
                    let y = plane == .axial ? row : plane == .coronal ? index : column
                    let z = plane == .axial ? index : volume.depth-1-row
                    let expected = calibrationGray(Double(volume.value(x: x,y: y,z: z)),center: 0,window: 1600,inverted: volume.monochrome1)
                    grayDifference = max(grayDifference,abs(Int(bytes[row*width+column])-Int(expected)))
                    pixelsChecked += 1
                }
            }
            expect(grayDifference <= 1,"CT reference MPR preserves source axes, intensity and display contrast")
        }
        let view = SliceView(model: model,plane: plane)
        let a = CGPoint(x: Double(width)*0.3,y: Double(height)*0.3)
        for length in [5.0,10,20,50] {
            let b = CGPoint(x: a.x+0.6*length/sx,y: a.y+0.8*length/sy)
            expect(b.x < Double(width) && b.y < Double(height),"CT reference ruler endpoints are inside the acquired image")
            for size in [CGSize(width: 400,height: 300),CGSize(width: 1100,height: 800)] {
                view.frame = CGRect(origin: .zero,size: size)
                for zoom in [0.75,2.0] {
                    view.zoom = zoom; view.pan = CGPoint(x: 19,y: -31)
                    let mappedA = view.imagePoint(view.screenPoint(a)), mappedB = view.imagePoint(view.screenPoint(b))
                    let measured = view.distance(mappedA,mappedB)
                    maximumDistanceError = max(maximumDistanceError,abs(measured-length)); distances += 1
                    expect(abs(measured-length) < 1e-9,"CT reference ruler keeps millimetres with anisotropic spacing, zoom, pan and resize")
                    let p = model.patientPoint(plane,imagePoint: mappedA)!.vector
                    let q = model.patientPoint(plane,imagePoint: mappedB)!.vector
                    expect(abs(simd_distance(p,q)-length) < 1e-9,"CT reference point placement and ruler agree in physical coordinates")
                    let screenA = view.screenPoint(a), screenB = view.screenPoint(b)
                    expect(abs(abs((screenB.x-screenA.x)/(screenB.y-screenA.y))-0.75) < 1e-10,"CT reference display uses the same scale for horizontal and vertical millimetres")
                }
            }
        }
    }
    try writePrivateValidationReference(volume: volume,output: URL(fileURLWithPath: "output/ct-study-private-reference.json"))
    let previews = URL(fileURLWithPath: "output/ct-study-previews")
    try FileManager.default.createDirectory(at: previews,withIntermediateDirectories: true)
    for index in stride(from: volume.depth/12,to: volume.depth,by: max(1,volume.depth/12)) {
        let image = volume.slice(.axial,index: index,center: -500,window: 1500)!
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png,properties: [:])!.write(to: previews.appendingPathComponent("axial-\(index).png"))
    }
    let report: [String:Any] = ["status":"pass","dimensions":[volume.width,volume.height,volume.depth],
        "spacing_mm":[volume.spacing.x,volume.spacing.y,volume.spacing.z],"mpr_samples_checked":pixelsChecked,
        "dicom_calibrated_distances_checked":distances,"maximum_distance_error_mm":maximumDistanceError,
        "scope":"Import and DICOM coordinate/display consistency. These distances are defined from DICOM geometry, not measured phantom object diameters."]
    try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: "output/ct-study-validation.json"))
    print("CT study PASS: \(volume.depth) slices, \(distances) DICOM-calibrated distances; physical object ground truth remains separate")
}
