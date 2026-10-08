import AppKit
import Combine
import SwiftUI
import ImageIO
import simd

enum Tool: String, CaseIterable, Identifiable {
    case navigate = "Navegar", measure = "Medir", window = "Contraste", arch = "Curva dental", implant = "Implante", canal = "Canal mandibular"
    var id: String { rawValue }
    var icon: String { switch self { case .navigate: return "scope"; case .measure: return "ruler"; case .window: return "circle.lefthalf.filled"; case .arch: return "point.topleft.down.to.point.bottomright.curvepath"; case .implant: return "screwdriver"; case .canal: return "point.topleft.down.to.point.bottomright.curvepath" } }
}
struct SliceMeasurement {
    var plane: Plane, slice: Int
    var start: CGPoint, end: CGPoint
    var mm: Double
}

final class ViewerModel: ObservableObject {
    @Published var volume: CTVolume?
    @Published var scan: StudyScan?
    @Published var selectedSeries = ""
    @Published var loading = false
    @Published var progress = 0.0
    @Published var status = "Abrí la carpeta de un estudio DICOM o de Xelis."
    @Published var error: String?
    @Published var x = 0.0
    @Published var y = 0.0
    @Published var z = 0.0
    @Published var center = 600.0
    @Published var window = 2800.0
    @Published var tool: Tool = .navigate
    @Published var crosshair = true
    @Published var threshold = 650.0
    @Published var measurements: [SliceMeasurement] = []
    @Published var panoramicMeasurements: [PanoramicMeasurement] = []
    @Published var transverseMeasurements: [TransverseMeasurement] = []
    @Published var resetToken = 0
    @Published var planning = PlanningData()
    @Published var selectedImplantID: UUID? {
        didSet { if oldValue != selectedImplantID { useCustomImplantDiameter = false; useCustomImplantLength = false } }
    }
    @Published var useCustomImplantDiameter = false
    @Published var useCustomImplantLength = false
    @Published var selectedCanalID: UUID? {
        didSet { if oldValue != selectedCanalID { selectedCanalPoint = nil; reviewDistance = 0 } }
    }
    @Published var selectedCanalPoint: Int?
    @Published var canalInteraction: CanalInteraction = .draw
    @Published var canalHistory = CanalHistory()
    @Published var reviewSourceIndex: Int?
    @Published var sourceCanalIndex = 0 {
        didSet {
            guard oldValue != sourceCanalIndex, let project = xelisProject,
                  project.canals.indices.contains(sourceCanalIndex) else { return }
            if reviewCanal && reviewSourceIndex != nil { reviewOriginalCanal() }
            else { focusXelisCanal() }
        }
    }
    @Published var reviewCanal = false
    @Published var reviewDistance = 0.0
    @Published var reviewField = 24.0
    @Published var reviewLongitudinal = false
    @Published var showPlanning = true
    @Published var xelisProject: XelisProject?
    @Published var showXelisCanals = true
    @Published var xelisStatus = ""
    @Published var focusedPanel: ViewerPanel?
    @Published var enlargedTransverseIndex: Int?
    @Published var dentalLayout = true {
        didSet { focusedPanel = nil; enlargedTransverseIndex = nil }
    }
    func togglePanel(_ panel: ViewerPanel) {
        focusedPanel = focusedPanel == panel ? nil : panel
        enlargedTransverseIndex = nil
    }
    func panelIsVisible(_ panel: ViewerPanel) -> Bool { focusedPanel == nil || focusedPanel == panel }
    @Published var archPoints: [CGPoint] = []
    var archRevision = 0
    var panoramicRevision = 0
    @Published var archCurve: ArchCurve? {
        didSet { archRevision += 1; panoramicRevision += 1; panoramicMeasurements = []; transverseMeasurements = [] }
    }
    @Published var archDistance = 0.0
    @Published var transverseSpacing = 1.0
    @Published var transverseField = 25.0
    @Published var panoramicThickness = 1.0
    @Published var panoramicOffset = 0.0 {
        didSet { if oldValue != panoramicOffset { panoramicRevision += 1; panoramicMeasurements = [] } }
    }
    var panoramicCurve: ArchCurve? { archCurve?.displaced(by: panoramicOffset) }
    func movePanoramicDepth(_ delta: Double) { panoramicOffset = min(10,max(-10,panoramicOffset+delta)) }
    var editingArchPoint: Int?
    var folder: URL?
    private var generation = 0

    func openPanel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Seleccioná el estudio completo o su carpeta Data."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        xelisProject = nil; xelisStatus = ""
        generation += 1; let current = generation
        folder = url; loading = true; progress = 0; error = nil; resetCanalEditing(); focusedPanel = nil; enlargedTransverseIndex = nil
        volume = nil; scan = nil; measurements = []; archCurve = nil; selectedSeries = ""
        status = "Buscando series DICOM…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try StudyLoader.scan(url)
                DispatchQueue.main.async {
                    guard self.generation == current else { return }
                    self.scan = result
                    self.loadSeries(result.series[0].id)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == current else { return }
                    self.loading = false; self.error = error.localizedDescription; self.status = "No se pudo abrir el estudio."
                }
            }
        }
    }
    func loadSeries(_ id: String) {
        guard let series = scan?.series.first(where: { $0.id == id }) else { return }
        xelisProject = nil; xelisStatus = ""
        generation += 1; let current = generation
        selectedSeries = id; loading = true; progress = 0; volume = nil; measurements = []; archCurve = nil
        planning = PlanningData(); selectedImplantID = nil; selectedCanalID = nil; resetCanalEditing()
        let projects = scan?.xelisProjects ?? []
        status = "Reconstruyendo el volumen…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try CTVolume(series: series) { fraction in
                    DispatchQueue.main.async { if self.generation == current { self.progress = fraction } }
                }
                var saved: XelisProject?, projectStatus = "Sin trazados guardados de Xelis."
                let matching = projects.filter { $0.string(0x0020000D) == result.studyUID }
                if matching.count == 1 {
                    do {
                        saved = try XelisProject.load(matching[0],volume: result)
                        projectStatus = "\(saved!.canals.count) canales originales de Xelis · \(saved!.canals.reduce(0) { $0+$1.points.count }) coordenadas guardadas."
                    } catch { projectStatus = error.localizedDescription }
                } else if matching.count > 1 { projectStatus = "Hay varios proyectos Xelis: no se eligió un trazado automáticamente." }
                let imported = saved, importStatus = projectStatus
                DispatchQueue.main.async {
                    guard self.generation == current else { return }
                    self.xelisProject = imported; self.xelisStatus = importStatus; self.showXelisCanals = true
                    self.volume = result; self.loading = false
                    self.reset()
                    self.initializeDentalCurve()
                    if imported != nil { self.focusXelisCanal() }
                    self.status = "\(result.depth) cortes · \(result.width) × \(result.height) · DICOM original"
                    if let folder = self.folder { UserDefaults.standard.set(folder.path, forKey: "lastStudy") }

                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == current else { return }
                    self.loading = false; self.error = error.localizedDescription; self.status = "La serie no pudo reconstruirse."
                }
            }
        }
    }
    func reset() {
        guard let v = volume else { return }
        x = Double(v.width / 2); y = Double(v.height / 2); z = Double(v.depth / 2)
        center = v.defaultCenter; window = v.defaultWidth; threshold = 650
        resetToken += 1
    }
    var reviewedCanal: NerveCanal? {
        if let i = reviewSourceIndex { return xelisProject?.reviewCanals[safe: i] }
        return selectedCanal
    }
    func reviewOriginalCanal() {
        guard let project = xelisProject, project.canals.indices.contains(sourceCanalIndex) else { return }
        reviewSourceIndex = sourceCanalIndex; reviewDistance = 0; reviewCanal = true
        if let v = volume, let p = project.canals[sourceCanalIndex].points.first {
            let q = (p-v.origin)/v.spacing
            x = q.x; y = q.y; z = q.z
        }
    }
    func focusXelisCanal() {
        guard let p = xelisProject?.canals[safe: sourceCanalIndex]?.controls.dropFirst().first, let v = volume else { return }
        let q = (p-v.origin)/v.spacing
        x = q.x.rounded(); y = q.y.rounded(); z = q.z.rounded()
        if let curve = archCurve {
            let xy = SIMD2(p.x-v.origin.x,p.y-v.origin.y)
            if let i = curve.samples.indices.min(by: { simd_length_squared(curve.samples[$0].position-xy) < simd_length_squared(curve.samples[$1].position-xy) }) { archDistance = curve.distances[i] }
        }
    }
    func index(_ plane: Plane) -> Int { switch plane { case .axial: return Int(z); case .coronal: return Int(y); case .sagittal: return Int(x) } }
    func move(_ plane: Plane, delta: Int) {
        guard let v = volume else { return }
        switch plane {
        case .axial: z = min(Double(v.depth - 1), max(0, z + Double(delta)))
        case .coronal: y = min(Double(v.height - 1), max(0, y + Double(delta)))
        case .sagittal: x = min(Double(v.width - 1), max(0, x + Double(delta)))
        }
    }
    func navigate(_ plane: Plane, point: CGPoint) {
        guard let v = volume else { return }
        switch plane {
        case .axial: x = min(Double(v.width - 1), max(0, point.x)); y = min(Double(v.height - 1), max(0, point.y))
        case .coronal: x = min(Double(v.width - 1), max(0, point.x)); z = min(Double(v.depth - 1), max(0, Double(v.depth - 1) - point.y))
        case .sagittal: y = min(Double(v.height - 1), max(0, point.x)); z = min(Double(v.depth - 1), max(0, Double(v.depth - 1) - point.y))
        }
    }
    var selectedImplant: PlannedImplant? { planning.implants.first { $0.id == selectedImplantID } }
    var selectedCanal: NerveCanal? { planning.canals.first { $0.id == selectedCanalID } }
    var referencePoint: PatientPoint? {
        guard let v = volume else { return nil }
        return PatientPoint(v.origin + SIMD3(x,y,z) * v.spacing)
    }
    func patientPoint(_ plane: Plane, imagePoint p: CGPoint) -> PatientPoint? {
        guard let v = volume else { return nil }
        var voxel: SIMD3<Double>
        switch plane {
        case .axial: voxel = SIMD3(p.x,p.y,Double(index(plane)))
        case .coronal: voxel = SIMD3(p.x,Double(index(plane)),Double(v.depth - 1)-p.y)
        case .sagittal: voxel = SIMD3(Double(index(plane)),p.x,Double(v.depth - 1)-p.y)
        }
        voxel = simd_min(simd_max(voxel, SIMD3(repeating: 0)), SIMD3(Double(v.width-1),Double(v.height-1),Double(v.depth-1)))
        return PatientPoint(v.origin + voxel * v.spacing)
    }
    func addImplant(at point: PatientPoint? = nil) {
        guard planning.implants.count < 100, planning.primitiveCount < 256, let point = point ?? referencePoint else { return }
        var implant = PlannedImplant(entry: point); implant.name = "Genérico \(planning.implants.count + 1)"
        planning.implants.append(implant); selectedImplantID = implant.id; tool = .implant
    }
    func positionImplant(at point: PatientPoint) {
        if let i = planning.implants.firstIndex(where: { $0.id == selectedImplantID }) { planning.implants[i].entry = point }
        else { addImplant(at: point) }
    }
    func updateImplant(_ field: WritableKeyPath<PlannedImplant, Double>, value: Double) {
        guard value.isFinite, let i = planning.implants.firstIndex(where: { $0.id == selectedImplantID }) else { return }
        let range: ClosedRange<Double>
        switch field {
        case \PlannedImplant.diameter: range = ImplantDimensions.diameterRange
        case \PlannedImplant.length: range = ImplantDimensions.lengthRange
        default: range = -85...85
        }
        planning.implants[i][keyPath: field] = min(range.upperBound,max(range.lowerBound,value))
    }
    func removeImplant() { planning.implants.removeAll { $0.id == selectedImplantID }; selectedImplantID = planning.implants.last?.id }
    func resetCanalEditing() {
        canalHistory = CanalHistory(); selectedCanalPoint = nil; reviewCanal = false; reviewSourceIndex = nil; sourceCanalIndex = 0
    }
    func mutateCanals(record: Bool = true, _ change: (inout [NerveCanal]) -> Void) -> Bool {
        var next = planning.canals; change(&next)
        guard next != planning.canals else { return false }
        guard next.count <= 10, planning.implants.count + next.reduce(0,{ $0+$1.primitiveCount }) <= 256 else {
            error = "Se alcanzó el límite de 256 elementos 3D. Desactivá la curva suave o quitá puntos antes de agregar más."; return false
        }
        if record { canalHistory.record(planning.canals) }
        planning.canals = next
        return true
    }
    func addCanal() {
        guard planning.canals.count < 10 else { error = "El máximo es 10 canales por plan."; return }
        let number = (1...100).first { n in !planning.canals.contains { $0.name == "Canal \(n)" } } ?? 1
        let canal = NerveCanal(name: "Canal \(number)",color: planning.canals.count.isMultiple(of: 2) ? .orange : .cyan)
        if mutateCanals({ $0.append(canal) }) { selectedCanalID = canal.id; tool = .canal; canalInteraction = .draw }
    }
    func updateCanal<Value>(_ field: WritableKeyPath<NerveCanal,Value>, value: Value) {
        guard let i = planning.canals.firstIndex(where: { $0.id == selectedCanalID }) else { return }
        if mutateCanals({ $0[i][keyPath: field] = value }), let j = selectedCanalPoint, planning.canals[i].points.indices.contains(j) {
            reviewDistance = planning.canals[i].path.distances[j * planning.canals[i].path.subdivisions]
        }
    }
    @discardableResult func addCanalPoint(_ point: PatientPoint, after index: Int? = nil) -> Bool {
        if selectedCanal == nil { addCanal() }
        guard let i = planning.canals.firstIndex(where: { $0.id == selectedCanalID }), planning.canals[i].points.count < 1000 else { return false }
        let insertion = index.map { min(planning.canals[i].points.count,max(0,$0+1)) } ?? planning.canals[i].points.count
        if insertion > 0, simd_distance(planning.canals[i].points[insertion-1].vector,point.vector) < 0.01 { return false }
        if insertion < planning.canals[i].points.count, simd_distance(planning.canals[i].points[insertion].vector,point.vector) < 0.01 { return false }
        if mutateCanals({ $0[i].points.insert(point,at: insertion); $0[i].visible = true }) { selectedCanalPoint = insertion; return true }
        return false
    }
    func moveCanalPoint(_ point: PatientPoint, in plane: Plane? = nil, record: Bool = true) {
        guard let i = planning.canals.firstIndex(where: { $0.id == selectedCanalID }), let j = selectedCanalPoint,
              planning.canals[i].points.indices.contains(j) else { return }
        var p = point
        // Dragging in one plane preserves the control point's coordinate normal to that plane.
        if let plane {
            let original = planning.canals[i].points[j]
            switch plane { case .axial: p.z = original.z; case .coronal: p.y = original.y; case .sagittal: p.x = original.x }
        }
        if mutateCanals(record: record,{ $0[i].points[j] = p }) {
            reviewDistance = planning.canals[i].path.distances[j * planning.canals[i].path.subdivisions]
        }
    }
    func selectCanalPoint(_ index: Int, centerViews: Bool = true) {
        guard let canal = selectedCanal, canal.points.indices.contains(index), let v = volume else { return }
        selectedCanalPoint = index
        reviewDistance = canal.path.distances[index * canal.path.subdivisions]
        if centerViews {
            let q = (canal.points[index].vector-v.origin)/v.spacing
            x = min(Double(v.width-1),max(0,q.x)); y = min(Double(v.height-1),max(0,q.y)); z = min(Double(v.depth-1),max(0,q.z))
        }
    }
    func deleteCanalPoint() {
        guard let i = planning.canals.firstIndex(where: { $0.id == selectedCanalID }), let j = selectedCanalPoint,
              planning.canals[i].points.indices.contains(j) else { return }
        if mutateCanals({ $0[i].points.remove(at: j) }) {
            selectedCanalPoint = planning.canals[i].points.isEmpty ? nil : min(j,planning.canals[i].points.count-1)
            if let index = selectedCanalPoint { selectCanalPoint(index) }
        }
    }
    func undoCanalPoint() {
        guard let canal = selectedCanal, !canal.points.isEmpty else { return }
        selectedCanalPoint = canal.points.count-1; deleteCanalPoint()
    }
    func removeCanal() {
        if mutateCanals({ $0.removeAll { $0.id == selectedCanalID } }) { selectedCanalID = planning.canals.last?.id; selectedCanalPoint = nil; reviewCanal = false }
    }
    func undoCanalEdit() {
        guard let candidate = canalHistory.past.last else { return }
        guard planning.implants.count+candidate.reduce(0,{ $0+$1.primitiveCount }) <= 256 else { error = "Quitá implantes antes de recuperar este trazado: excede el límite de elementos 3D."; return }
        if let previous = canalHistory.undo(planning.canals) { planning.canals = previous; recoverCanalSelection() }
    }
    func redoCanalEdit() {
        guard let candidate = canalHistory.future.last else { return }
        guard planning.implants.count+candidate.reduce(0,{ $0+$1.primitiveCount }) <= 256 else { error = "Quitá implantes antes de recuperar este trazado: excede el límite de elementos 3D."; return }
        if let next = canalHistory.redo(planning.canals) { planning.canals = next; recoverCanalSelection() }
    }
    func recoverCanalSelection() {
        if selectedCanal == nil { selectedCanalID = planning.canals.first?.id }
        selectedCanalPoint = nil
        if selectedCanal == nil { reviewCanal = false }
        reviewDistance = min(reviewDistance,selectedCanal?.path.length ?? 0)
    }
    func updateCanalCoordinate(_ axis: Int, value: Double) {
        guard value.isFinite, let canal = selectedCanal, let j = selectedCanalPoint, canal.points.indices.contains(j), let v = volume else { return }
        var p = canal.points[j].vector
        let end = v.origin+SIMD3(Double(v.width-1),Double(v.height-1),Double(v.depth-1))*v.spacing
        p[axis] = min(end[axis],max(v.origin[axis],value)); moveCanalPoint(PatientPoint(p))
    }
    func reviewProximity(_ hit: PlanningGeometry.CanalProximity) {
        reviewSourceIndex = nil; selectedCanalID = hit.canalID; reviewDistance = hit.distanceAlong; reviewCanal = true
        if let v = volume {
            let q = (hit.pair.canal-v.origin)/v.spacing
            x = min(Double(v.width-1),max(0,q.x)); y = min(Double(v.height-1),max(0,q.y)); z = min(Double(v.depth-1),max(0,q.z))
        }
    }
    func savePlan() {
        guard let v = volume else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Planificacion.dentalplan.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = PlanningDocument(volume: v,planning: planning); try document.validate(for: v)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    func loadPlan() {
        guard let v = volume else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Abrí una planificación .dentalplan.json correspondiente a esta serie."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 10_000_000 else { throw ViewerError.message("El archivo de planificación es demasiado grande.") }
            let document = try JSONDecoder().decode(PlanningDocument.self,from: data); try document.validate(for: v)
            resetCanalEditing(); planning = document.planning; selectedImplantID = planning.implants.first?.id; selectedCanalID = planning.canals.first?.id
        } catch { self.error = error.localizedDescription }
    }
    func exportWindow() {
        let appWindow = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.title == "DentalViewer" })
        guard volume != nil, let view = appWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "DentalViewer.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // AppKit's view cache omits CAMetalLayer content. Render that pane offscreen and composite it.
        func metalViews(_ parent: NSView) -> [VolumeMetalView] {
            parent.subviews.flatMap { child -> [VolumeMetalView] in
                if let metal = child as? VolumeMetalView { return [metal] }; return metalViews(child)
            }
        }
        do {
            guard let base = rep.cgImage,
                  let context = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ViewerError.message("No se pudo preparar la captura PNG.")
            }
            context.draw(base, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            context.scaleBy(x: Double(rep.pixelsWide) / view.bounds.width, y: Double(rep.pixelsHigh) / view.bounds.height)
            for metal in metalViews(view) {
                guard let image = metal.snapshotImage() else { continue }
                var rect = metal.convert(metal.bounds, to: view)
                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                context.draw(image, in: rect)
            }
            guard let result = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw ViewerError.message("No se pudo generar la captura PNG.") }
            CGImageDestinationAddImage(destination, result, nil)
            guard CGImageDestinationFinalize(destination) else { throw ViewerError.message("No se pudo guardar la captura PNG.") }
        }
        catch { self.error = error.localizedDescription }
    }
}

struct ViewerRoot: View {
    @ObservedObject var model: ViewerModel
    let accent = Color(red: 0.25, green: 0.82, blue: 0.76)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 21)).foregroundColor(accent)
                Text("DentalViewer").font(.system(size: 19, weight: .semibold))
                Text("para macOS").foregroundColor(.secondary)
                Picker("Vista principal",selection: $model.dentalLayout) {
                    Text("Dental").tag(true); Text("MPR").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Spacer()
                Button { model.openPanel() } label: { Label("Abrir estudio", systemImage: "folder") }.keyboardShortcut("o")
                Button { model.savePlan() } label: { Label("Guardar plan", systemImage: "square.and.arrow.down") }.disabled(model.volume == nil)
                Button { model.loadPlan() } label: { Text("Cargar plan") }.disabled(model.volume == nil)
                Button { model.reset() } label: { Image(systemName: "arrow.counterclockwise") }.help("Restablecer vistas").disabled(model.volume == nil)
                Button { model.exportWindow() } label: { Label("Captura", systemImage: "square.and.arrow.up") }.disabled(model.volume == nil)
            }.padding(.horizontal, 22).padding(.vertical, 16).background(Color(white: 0.115))
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 265).background(Color(white: 0.09))
                Divider()
                ZStack {
                    Color(white: 0.055)
                    if model.volume != nil {
                        GeometryReader { geometry in workspace(geometry.size) }.padding(10)
                    } else {
                        VStack(spacing: 18) {
                            Image(systemName: model.loading ? "cube.transparent" : "folder.badge.plus")
                                .font(.system(size: 52, weight: .ultraLight)).foregroundColor(accent)
                            Text(model.loading ? "Preparando el estudio" : "Tus estudios, en tu Mac").font(.title2.weight(.medium))
                            Text(model.status).foregroundColor(.secondary).multilineTextAlignment(.center)
                            if model.loading { ProgressView(value: model.progress).frame(width: 280) }
                            else { Button("Seleccionar carpeta…") { model.openPanel() }.buttonStyle(.borderedProminent).tint(accent) }
                        }.padding(40)
                    }
                }
            }
            Divider()
            HStack {
                Circle().fill(model.volume != nil ? accent : Color.gray).frame(width: 6, height: 6)
                Text(model.status)
                Spacer()
                Text("Procesamiento local · Prototipo de visualización")
            }.font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 18).padding(.vertical, 8).background(Color(white: 0.1))
        }.frame(minWidth: ViewerWindowLayout.minimumContentSize.width,minHeight: ViewerWindowLayout.minimumContentSize.height)
        .preferredColorScheme(.dark)
        .alert("No se pudo completar la operación", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Aceptar", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    func workspace(_ size: CGSize) -> some View {
        let gap = 8.0
        let imageHeight = max(1,size.height-(model.dentalLayout ? 93 : 0))
        let halfHeight = max(1,(imageHeight-gap)/2)
        let leftWidth = max(1,(size.width-gap)*(model.dentalLayout ? 0.61 : 0.5))
        let rightWidth = max(1,size.width-gap-leftWidth)
        let leftTop = CGRect(x: 0,y: 0,width: leftWidth,height: halfHeight)
        let leftBottom = CGRect(x: 0,y: halfHeight+gap,width: leftWidth,height: halfHeight)
        let rightTop = CGRect(x: leftWidth+gap,y: 0,width: rightWidth,height: halfHeight)
        let rightBottom = CGRect(x: leftWidth+gap,y: halfHeight+gap,width: rightWidth,height: halfHeight)
        return ZStack(alignment: .topLeading) {
            if model.dentalLayout {
                DentalReformatPanel(model: model,panoramic: false)
                    .modifier(PanelPresentation(model: model,panel: .transverse,normal: leftTop,workspace: size))
                DentalReformatPanel(model: model,panoramic: true)
                    .modifier(PanelPresentation(model: model,panel: .panoramic,normal: leftBottom,workspace: size))
                IntensityPanel(model: model).frame(width: size.width).offset(y: imageHeight+gap)
                    .opacity(model.focusedPanel == nil ? 1 : 0).allowsHitTesting(model.focusedPanel == nil).accessibilityHidden(model.focusedPanel != nil)
            } else {
                slicePanel(.coronal,color: .orange)
                    .modifier(PanelPresentation(model: model,panel: .coronal,normal: leftBottom,workspace: size))
                slicePanel(.sagittal,color: .purple)
                    .modifier(PanelPresentation(model: model,panel: .sagittal,normal: rightBottom,workspace: size))
            }
            slicePanel(.axial,color: accent)
                .modifier(PanelPresentation(model: model,panel: .axial,normal: model.dentalLayout ? rightTop : leftTop,workspace: size))
            Group { if model.reviewCanal { CanalReviewPanel(model: model) } else { volumePanel } }
                .modifier(PanelPresentation(model: model,panel: .volume,normal: model.dentalLayout ? rightBottom : rightTop,workspace: size))
        }.frame(width: size.width,height: size.height,alignment: .topLeading)
    }
    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    heading("ESTUDIO")
                    Text(model.volume?.patient ?? "Sin estudio abierto").font(.system(size: 16, weight: .medium)).textSelection(.enabled)
                    if let v = model.volume {
                        Text("\(v.description) · \(formattedDate(v.studyDate))").foregroundColor(.secondary).font(.system(size: 12))
                        Text("\(v.width) × \(v.height) × \(v.depth)").font(.system(size: 12, design: .monospaced))
                        Text(String(format: "Vóxel %.3f × %.3f × %.3f mm", v.spacing.x, v.spacing.y, v.spacing.z)).foregroundColor(.secondary).font(.system(size: 11))
                    }
                    if let scan = model.scan, scan.series.count > 1 {
                        Picker("Serie", selection: Binding(get: { model.selectedSeries }, set: { model.loadSeries($0) })) {
                            ForEach(scan.series) { Text($0.label).tag($0.id) }
                        }.disabled(model.loading)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    heading("HERRAMIENTAS")
                    ForEach(Tool.allCases) { tool in
                        Button { model.selectTool(tool) } label: {
                            HStack { Image(systemName: tool.icon).frame(width: 20); Text(tool.rawValue); Spacer(); if model.tool == tool { Image(systemName: "checkmark") } }
                                .padding(9).contentShape(Rectangle())
                                .background(model.tool == tool ? accent.opacity(0.15) : Color.clear).cornerRadius(6)
                        }.buttonStyle(.plain).foregroundColor(model.tool == tool ? accent : .primary)
                            .disabled(tool == .arch && model.xelisProject != nil)
                            .help(tool == .arch && model.xelisProject != nil ? "La curva original de Xelis está protegida. Se usa su geometría guardada." : tool.rawValue)
                    }
                    Toggle("Líneas de referencia", isOn: $model.crosshair).font(.system(size: 12)).toggleStyle(.switch)
                }.disabled(model.volume == nil)
                if model.volume != nil, model.dentalLayout {
                    VStack(alignment: .leading,spacing: 8) {
                        heading("CURVA DENTAL")
                        if model.xelisProject != nil {
                            Text("Curva original guardada en Xelis. Se conservan sus puntos y orientación.").font(.system(size: 10)).foregroundColor(.secondary)
                        } else {
                            Button("Definir curva en axial") { model.tool = .arch }.controlSize(.small)
                            Text("Hacé clic para agregar puntos; arrastrá un punto para corregirlo.").font(.system(size: 10)).foregroundColor(.secondary)
                            Button("Borrar curva manual") { model.initializeDentalCurve() }.controlSize(.small)
                        }
                        PlanningSidebar(model: model).dimension("Campo transversal",value: $model.transverseField,range: 10...50,unit: "mm")
                    }
                }
                if model.volume != nil { PlanningSidebar(model: model) }
                VStack(alignment: .leading, spacing: 12) {
                    heading("IMAGEN")
                    HStack(spacing: 6) {
                        Button("Original") { if let v = model.volume { model.center = v.defaultCenter; model.window = v.defaultWidth } }
                        Button("Hueso") { model.center = 600; model.window = 2800 }
                        Button("Tejido") { model.center = 40; model.window = 400 }
                    }.font(.system(size: 11)).controlSize(.small)
                    control("Centro", value: $model.center, range: -1200...3500)
                    control("Ventana", value: $model.window, range: 1...7000)
                    heading("RECONSTRUCCIÓN 3D")
                    control("Umbral", value: $model.threshold, range: -500...2500)
                    Text("El umbral usa la intensidad reescalada del DICOM; en CBCT no implica densidad ósea calibrada.").font(.system(size: 10)).foregroundColor(.secondary)
                }.disabled(model.volume == nil)
                if let v = model.volume {
                    VStack(alignment: .leading, spacing: 8) {
                        heading("POSICIÓN")
                        Text(String(format: "L %.1f · P %.1f · S %.1f mm", v.origin.x + model.x * v.spacing.x, v.origin.y + model.y * v.spacing.y, v.origin.z + model.z * v.spacing.z))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        Text(String(format: "Intensidad: %.0f", v.value(x: Int(model.x), y: Int(model.y), z: Int(model.z))))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                if !model.measurements.isEmpty || !model.panoramicMeasurements.isEmpty || !model.transverseMeasurements.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { heading("MEDICIONES"); Spacer(); Button { model.measurements = []; model.panoramicMeasurements = []; model.transverseMeasurements = [] } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel("Borrar mediciones") }
                        ForEach(Array(model.measurements.enumerated()), id: \.offset) { _, m in
                            Text(String(format: "%@ · corte %d · %.2f mm", m.plane.rawValue, m.slice + 1, m.mm)).font(.system(size: 11, design: .monospaced))
                        }
                        ForEach(model.panoramicMeasurements) { m in
                            Text(String(format: "Panorámica · %.2f mm",m.mm)).font(.system(size: 11,design: .monospaced))
                        }
                        ForEach(model.transverseMeasurements) { m in
                            Text(String(format: "Transversal · %.1f mm del arco · %.2f mm",model.archCurve?.distances[safe: m.section] ?? 0,m.mm)).font(.system(size: 11,design: .monospaced))
                        }
                    }
                }
                if let scan = model.scan {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.xelisProject != nil {
                            Text("Curva dental y canales recuperados del proyecto Xelis original.").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        if scan.compressedFiles > 0 {
                            Text("\(scan.compressedFiles) imágenes comprimidas sin soporte de decodificación.").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        if !scan.failures.isEmpty {
                            Text("\(scan.failures.count) archivo(s) no se pudieron leer.").font(.system(size: 11)).foregroundColor(.orange)
                            Text(scan.failures.prefix(3).joined(separator: "\n")).font(.system(size: 10)).foregroundColor(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Text("Rueda: cortes · ⌘ rueda: zoom\nArrastrar: herramienta activa\n⌥ arrastrar: mover imagen\n3D: arrastrar para rotar").font(.system(size: 11)).foregroundColor(.secondary).lineSpacing(4)
            }.padding(18)
        }
    }
    func heading(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundColor(.secondary) }
    func control(_ text: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack { Text(text); Spacer(); Text(String(format: "%.0f", value.wrappedValue)).monospacedDigit().foregroundColor(accent) }.font(.system(size: 12))
            Slider(value: value, in: range).tint(accent).controlSize(.small)
        }
    }
    func slicePanel(_ plane: Plane, color: Color) -> some View {
        VStack(spacing: 0) {
            HStack { Circle().fill(color).frame(width: 6, height: 6); Text(plane.rawValue).font(.system(size: 12, weight: .medium)); Spacer(); Text("\(model.index(plane) + 1) / \(sliceCount(plane))").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary); PanelExpandButton(model: model,panel: ViewerPanel(plane: plane)) }.padding(.horizontal, 12).padding(.vertical, 9)
            SliceRepresentable(model: model, plane: plane)
            HStack { Image(systemName: "square.stack").foregroundColor(.secondary); Slider(value: positionBinding(plane), in: 0...Double(max(1, sliceCount(plane) - 1)), step: 1).tint(color) }.padding(.horizontal, 12).padding(.vertical, 6).controlSize(.small)
        }.background(Color(white: 0.11)).cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
    var volumePanel: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "cube").foregroundColor(accent); Text("Volumen 3D").font(.system(size: 12, weight: .medium)); Spacer(); Text("Metal").font(.system(size: 10)).foregroundColor(.secondary); PanelExpandButton(model: model,panel: .volume) }.padding(.horizontal, 12).padding(.vertical, 9)
            VolumeRepresentable(model: model)
            Text("Rotar: arrastrar · Zoom: rueda · Doble clic: restablecer").font(.system(size: 10)).foregroundColor(.secondary).padding(9)
        }.background(Color(white: 0.11)).cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
    func sliceCount(_ plane: Plane) -> Int { guard let v = model.volume else { return 1 }; switch plane { case .axial: return v.depth; case .coronal: return v.height; case .sagittal: return v.width } }
    func positionBinding(_ plane: Plane) -> Binding<Double> { switch plane { case .axial: return $model.z; case .coronal: return $model.y; case .sagittal: return $model.x } }
    func formattedDate(_ s: String) -> String { guard s.count == 8 else { return s }; return "\(s.suffix(2))/\(s.dropFirst(4).prefix(2))/\(s.prefix(4))" }
}
