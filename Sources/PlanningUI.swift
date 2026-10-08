import SwiftUI
import simd

struct PlanningSidebar: View {
    @ObservedObject var model: ViewerModel
    private enum SizeChoice: Hashable { case preset(Double), custom }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PLANIFICACIÓN MANUAL").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundColor(.secondary)
            Toggle("Mostrar planificación", isOn: $model.showPlanning).font(.system(size: 12)).toggleStyle(.switch)
            HStack {
                Button { model.addImplant() } label: { Label("Implante",systemImage: "plus") }
                Button { model.addCanal() } label: { Label("Canal",systemImage: "plus") }
            }.controlSize(.small)
            if !model.planning.implants.isEmpty {
                Picker("Implante", selection: $model.selectedImplantID) {
                    ForEach(model.planning.implants) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden()
                if let implant = model.selectedImplant {
                    implantDimension("Ancho (diámetro)",value: implantBinding(\.diameter),presets: ImplantDimensions.diameters,range: ImplantDimensions.diameterRange,custom: $model.useCustomImplantDiameter)
                    implantDimension("Largo",value: implantBinding(\.length),presets: ImplantDimensions.lengths,range: ImplantDimensions.lengthRange,custom: $model.useCustomImplantLength)
                    dimension("Inclinación lateral", value: implantBinding(\.lateralAngle), range: -85...85, unit: "°")
                    dimension("Inclinación anterior", value: implantBinding(\.anteriorAngle), range: -85...85, unit: "°")
                    HStack {
                        Button("Al punto de referencia") { if let p = model.referencePoint { model.positionImplant(at: p) } }
                        Spacer(); Button { model.removeImplant() } label: { Image(systemName: "trash") }
                    }.controlSize(.small)
                    if let hit = PlanningGeometry.proximity(implant: implant,canals: model.planning.canals) {
                        let gap = hit.gap
                        Text(String(format: "Separación al trazado: %.2f mm",gap)).font(.system(size: 11,design: .monospaced)).foregroundColor(gap < 0 ? .orange : .secondary)
                        Text("Canal: \(hit.canalName) · incluye trazados ocultos").font(.system(size: 10)).foregroundColor(.secondary)
                        Button("Revisar punto más cercano") { model.reviewProximity(hit) }.controlSize(.small)
                        Text("Estimación geométrica con el implante genérico y los puntos manuales; no determina una distancia clínica segura.").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    if let v = model.volume {
                        let voxel = (implant.apex-v.origin)/v.spacing
                        if voxel.x < 0 || voxel.y < 0 || voxel.z < 0 || voxel.x > Double(v.width-1) || voxel.y > Double(v.height-1) || voxel.z > Double(v.depth-1) {
                            Text("El extremo del implante está fuera del volumen adquirido.").font(.system(size: 10)).foregroundColor(.orange)
                        }
                    }
                }
            }
            CanalSidebar(model: model)
            Text(model.tool == .canal ? "Trazar: clic para agregar. Editar: seleccioná y arrastrá un punto. Insertar: clic sobre un segmento. Suprimir: borrar el punto seleccionado. ⌥ arrastrar: desplazar la imagen." : "Con Implante, hacé clic o arrastrá en un corte para ubicar el seleccionado. La entrada se marca con un círculo.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text("Implantes roscados genéricos. Diámetro exterior y longitud total en mm. En 3D se superponen al hueso para mantenerlos visibles.").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
    func implantBinding(_ field: WritableKeyPath<PlannedImplant,Double>) -> Binding<Double> {
        Binding(get: { model.selectedImplant?[keyPath: field] ?? 0 },set: { model.updateImplant(field,value: $0) })
    }
    private func implantDimension(_ name: String, value: Binding<Double>, presets: [Double], range: ClosedRange<Double>, custom: Binding<Bool>) -> some View {
        let selection = Binding<SizeChoice>(get: {
            custom.wrappedValue || !presets.contains(value.wrappedValue) ? .custom : .preset(value.wrappedValue)
        },set: { choice in
            switch choice {
            case .custom: custom.wrappedValue = true
            case .preset(let size): custom.wrappedValue = false; value.wrappedValue = size
            }
        })
        let number = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "es_AR")).precision(.fractionLength(0...2))
        return VStack(alignment: .leading,spacing: 4) {
            HStack { Text(name); Spacer(); Text(value.wrappedValue.formatted(number)+" mm").monospacedDigit() }.font(.system(size: 11))
            Picker(name,selection: selection) {
                ForEach(presets,id: \.self) { size in Text(size.formatted(number)+" mm").tag(SizeChoice.preset(size)) }
                Text("Personalizado").tag(SizeChoice.custom)
            }.labelsHidden().controlSize(.small).accessibilityLabel(name+" del implante")
            if selection.wrappedValue == .custom {
                HStack {
                    TextField(name+" personalizado",value: value,format: number)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(name+" personalizado en mm")
                    Text("mm").foregroundColor(.secondary)
                    Stepper(name,value: value,in: range,step: 0.1).labelsHidden().controlSize(.small)
                        .accessibilityLabel("Ajustar "+name.lowercased()+" personalizado")
                }.font(.system(size: 11))
            }
        }
    }
    func dimension(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 4) {
            HStack { Text(name); Spacer(); Text(String(format: "%.1f %@",value.wrappedValue,unit)).monospacedDigit() }.font(.system(size: 11))
            Slider(value: value,in: range,step: unit == "°" ? 1 : 0.1).controlSize(.small)
        }
    }
}

struct CanalSidebar: View {
    @ObservedObject var model: ViewerModel
    func binding<T>(_ field: WritableKeyPath<NerveCanal,T>, fallback: T) -> Binding<T> {
        Binding(get: { model.selectedCanal?[keyPath: field] ?? fallback },set: { model.updateCanal(field,value: $0) })
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            Divider()
            Text("CANAL MANDIBULAR").font(.system(size: 10,weight: .semibold)).foregroundColor(.secondary)
            Text(model.xelisStatus.isEmpty ? "No hay un trazado guardado de Xelis en este estudio." : model.xelisStatus)
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false,vertical: true)
            if let project = model.xelisProject, !project.canals.isEmpty {
                Toggle("Mostrar canales originales",isOn: $model.showXelisCanals).font(.system(size: 11))
                Picker("Canal original",selection: $model.sourceCanalIndex) {
                    ForEach(project.canals.indices,id: \.self) { Text("Canal original \($0+1)").tag($0) }
                }.controlSize(.small)
                Button("Recorrer canal original") { model.reviewOriginalCanal() }.controlSize(.small)
                Button("Ver canal en los cortes") { model.focusXelisCanal() }.controlSize(.small)
                Text("Ambos canales se muestran en verde. Seleccionar uno centra sus cortes y cambia su revisión.").font(.system(size: 10)).foregroundColor(.green)
            }
            Divider()
            Text("TRAZADO Y REVISIÓN MANUAL").font(.system(size: 9,weight: .semibold)).foregroundColor(.secondary)
            HStack {
                Button("Deshacer canal") { model.undoCanalEdit() }.disabled(model.canalHistory.past.isEmpty).keyboardShortcut("z")
                Button("Rehacer") { model.redoCanalEdit() }.disabled(model.canalHistory.future.isEmpty).keyboardShortcut("z",modifiers: [.command,.shift])
            }.controlSize(.small)
            if !model.planning.canals.isEmpty {
                Picker("Canal",selection: $model.selectedCanalID) {
                    ForEach(model.planning.canals) { Text($0.name).tag(Optional($0.id)) }
                }
                if let canal = model.selectedCanal {
                    TextField("Nombre del canal",text: Binding(get: { model.selectedCanal?.name ?? "" },set: { model.updateCanal(\.name,value: String($0.prefix(100))) }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Nombre del canal")
                    HStack {
                        Picker("Lado",selection: binding(\.side,fallback: .unspecified)) { ForEach(CanalSide.allCases,id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("Color",selection: binding(\.color,fallback: .orange)) { ForEach(CanalColor.allCases,id: \.self) { Text($0.rawValue).tag($0) } }
                    }.controlSize(.small)
                    Toggle("Visible en cortes y 3D",isOn: binding(\.visible,fallback: true)).font(.system(size: 11))
                    Toggle("Curva suave",isOn: binding(\.smooth,fallback: false)).font(.system(size: 11))
                    Text(String(format: "%d puntos · longitud %.1f mm",canal.points.count,canal.path.length)).font(.system(size: 11)).foregroundColor(.secondary)
                    PlanningSidebar(model: model).dimension("Diámetro del trazado",value: binding(\.diameter,fallback: 2),range: 0.5...5,unit: "mm")
                    Picker("Acción en los cortes",selection: Binding(get: { model.canalInteraction },set: { model.canalInteraction = $0; model.tool = .canal })) {
                        ForEach(CanalInteraction.allCases,id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Picker("Punto",selection: Binding(get: { model.selectedCanalPoint },set: { if let index = $0 { model.selectCanalPoint(index) } else { model.selectedCanalPoint = nil } })) {
                        Text("Sin selección").tag(Optional<Int>.none)
                        ForEach(canal.points.indices,id: \.self) { Text("Punto \($0+1)").tag(Optional($0)) }
                    }
                    HStack {
                        Button("Anterior") { model.selectCanalPoint(max(0,(model.selectedCanalPoint ?? 1)-1)) }.disabled(canal.points.isEmpty)
                        Button("Siguiente") { model.selectCanalPoint(min(canal.points.count-1,(model.selectedCanalPoint ?? -1)+1)) }.disabled(canal.points.isEmpty)
                    }.controlSize(.small)
                    if let j = model.selectedCanalPoint, canal.points.indices.contains(j) {
                        ForEach(0..<3,id: \.self) { axis in
                            HStack {
                                Text(["L","P","S"][axis]).frame(width: 12)
                                TextField("Coordenada \(["L","P","S"][axis])",value: Binding(get: { model.selectedCanal?.points[safe: model.selectedCanalPoint ?? -1]?.vector[axis] ?? 0 },set: { model.updateCanalCoordinate(axis,value: $0) }),format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder)
                                Text("mm").foregroundColor(.secondary)
                            }.font(.system(size: 11))
                        }
                        Button("Borrar punto seleccionado") { model.deleteCanalPoint() }.controlSize(.small)
                    }
                    Button("Agregar en referencia") { if let p = model.referencePoint { model.addCanalPoint(p) } }.controlSize(.small)
                    Button("Insertar después del seleccionado") { if let p = model.referencePoint, let j = model.selectedCanalPoint { model.addCanalPoint(p,after: j) } }.disabled(model.selectedCanalPoint == nil).controlSize(.small)
                    Toggle("Revisar cortes del canal",isOn: Binding(get: { model.reviewCanal && model.reviewSourceIndex == nil },set: { model.reviewSourceIndex = nil; model.reviewCanal = $0 })).font(.system(size: 11)).disabled(canal.path.length < 0.001)
                    if canal.points.count < 2 { Text("Marcá al menos dos puntos para revisar el recorrido.").font(.system(size: 10)).foregroundColor(.secondary) }
                    Button("Eliminar canal seleccionado",role: .destructive) { model.removeCanal() }.controlSize(.small)
                }
            } else { Text("Agregá un canal y marcá sus puntos en los cortes.").font(.system(size: 11)).foregroundColor(.secondary) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
