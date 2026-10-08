import AppKit
import simd

extension ViewerModel {
    func dentalToolHint(panoramic: Bool) -> String {
        switch tool {
        case .navigate: return panoramic ? "Clic y arrastre: recorrer arco y altura" : "Clic y arrastre: ubicar referencia · rueda: recorrer arco"
        case .measure: return panoramic ? "Medir: clic y arrastre · distancia en la panorámica desplegada" : "Medir: clic y arrastre dentro de una sección · distancia en mm"
        case .window: return "Contraste: arrastrar verticalmente para Centro, horizontalmente para Ventana"
        case .implant: return panoramic ? "Implante: clic y arrastre sobre la profundidad mostrada" : "Implante: clic y arrastre sobre el corte transversal"
        case .canal: return panoramic ? "Canal manual: marcar o editar puntos sobre la profundidad mostrada" : "Canal manual: marcar o editar puntos en el corte transversal"
        case .arch: return "Curva dental: marcar y mover puntos en axial"
        }
    }
    func selectTool(_ tool: Tool) {
        guard tool != .arch || xelisProject == nil else { return }
        self.tool = tool
        if tool == .implant || tool == .canal { showPlanning = true }
        if tool == .arch { dentalLayout = true; focusedPanel = .axial }
    }
}

extension DentalImagesView {
    func interactionCell(at point: CGPoint) -> Int? {
        images.indices.first { i in
            (panoramic || model.enlargedTransverseIndex == nil || model.enlargedTransverseIndex == i)
                && cellRect(i).contains(point) && imageRect(i).contains(point)
        }
    }
    /// Panorama: fractional column/row. Transverse: physical offset/height in mm.
    func dentalImagePoint(_ point: CGPoint, cell: Int) -> CGPoint? {
        guard images.indices.contains(cell), let volume = renderedVolume else { return nil }
        let rect = imageRect(cell), image = images[cell]
        guard rect.width > 0, rect.height > 0 else { return nil }
        let pixel = PanoramicMeasurementGeometry.imagePoint(point,in: rect,columns: image.width,rows: image.height)
        if panoramic { return pixel }
        return CGPoint(x: renderedField*(pixel.x/Double(image.width-1)-0.5),
                       y: (Double(volume.depth-1)-pixel.y)*volume.spacing.z)
    }
    func dentalScreenPoint(_ point: CGPoint, cell: Int) -> CGPoint {
        guard images.indices.contains(cell), let volume = renderedVolume else { return .zero }
        if panoramic {
            return PanoramicMeasurementGeometry.screenPoint(point,in: imageRect(cell),columns: images[cell].width,rows: images[cell].height)
        }
        let image = images[cell]
        let pixel = CGPoint(x: (point.x/renderedField+0.5)*Double(image.width-1),
                            y: Double(volume.depth-1)-point.y/volume.spacing.z)
        return PanoramicMeasurementGeometry.screenPoint(pixel,in: imageRect(cell),columns: image.width,rows: image.height)
    }
    func dentalPatientPoint(_ point: CGPoint, cell: Int) -> SIMD3<Double>? {
        guard let curve = renderedCurve, let volume = renderedVolume else { return nil }
        if panoramic {
            let column = min(Double(curve.samples.count-1),max(0,point.x))
            let a = Int(column), b = min(a+1,curve.samples.count-1), fraction = column-Double(a)
            let height = (Double(volume.depth-1)-point.y)*volume.spacing.z
            let p = curve.localPosition(sample: curve.samples[a],height: height,offset: 0)
            let q = curve.localPosition(sample: curve.samples[b],height: height,offset: 0)
            return volume.origin+p+(q-p)*fraction
        }
        guard indices.indices.contains(cell) else { return nil }
        return volume.origin+curve.localPosition(sample: curve.samples[indices[cell]],height: point.y,offset: point.x)
    }
    func pointInsideVolume(_ point: SIMD3<Double>) -> Bool {
        guard let v = renderedVolume else { return false }
        let q = (point-v.origin)/v.spacing
        return (0..<3).allSatisfy { q[$0].isFinite && q[$0] >= 0 && q[$0] <= Double([v.width,v.height,v.depth][$0]-1) }
    }
    func beginDentalInteraction(at point: CGPoint) {
        cancelMeasurement()
        guard imageRevision == geometryRevision, previousVolume === model.volume,
              let cell = interactionCell(at: point), let mapped = dentalImagePoint(point,cell: cell) else { return }
        dragCell = cell; dragSection = panoramic ? nil : indices[cell]; dragTool = model.tool
        dragStart = point; startCenter = model.center; startWindow = model.window; canalDragRecorded = false
        measurementRevision = geometryRevision
        switch model.tool {
        case .measure: measureStart = mapped; measureEnd = mapped
        case .window: break
        case .navigate: navigateDentalPoint(mapped,cell: cell)
        case .implant:
            if let p = dentalPatientPoint(mapped,cell: cell), pointInsideVolume(p) {
                model.showPlanning = true; model.positionImplant(at: PatientPoint(p)); planningDragActive = true
            }
        case .canal:
            model.showPlanning = true
            if let hit = dentalCanalHit(at: point,cell: cell,segments: false) {
                model.selectedCanalID = hit.0; model.selectCanalPoint(hit.1,centerViews: false); planningDragActive = true
            } else if let p = dentalPatientPoint(mapped,cell: cell), pointInsideVolume(p) {
                if model.canalInteraction == .draw {
                    planningDragActive = model.addCanalPoint(PatientPoint(p)); canalDragRecorded = planningDragActive
                } else if model.canalInteraction == .insert, let hit = dentalCanalHit(at: point,cell: cell,segments: true) {
                    model.selectedCanalID = hit.0
                    planningDragActive = model.addCanalPoint(PatientPoint(p),after: hit.1); canalDragRecorded = planningDragActive
                }
            }
        case .arch: cancelMeasurement() // The curve is defined in axial, not on its own reconstruction.
        }
        needsDisplay = true
    }
    func dragDentalInteraction(to point: CGPoint) {
        guard let cell = dragCell, dragTool == model.tool else { cancelMeasurement(); return }
        if dragTool == .window {
            model.center = min(3500,max(-1200,startCenter-(point.y-dragStart.y)*5))
            model.window = min(7000,max(1,startWindow+(point.x-dragStart.x)*10)); return
        }
        guard measurementRevision == geometryRevision, panoramic || (indices.indices.contains(cell) && indices[cell] == dragSection),
              let mapped = dentalImagePoint(point,cell: cell) else { cancelMeasurement(); return }
        switch model.tool {
        case .measure: measureEnd = mapped
        case .navigate: navigateDentalPoint(mapped,cell: cell)
        case .implant:
            if planningDragActive, let p = dentalPatientPoint(mapped,cell: cell), pointInsideVolume(p) { model.positionImplant(at: PatientPoint(p)) }
        case .canal:
            if planningDragActive, let p = dentalPatientPoint(mapped,cell: cell), pointInsideVolume(p) {
                if !canalDragRecorded { model.canalHistory.record(model.planning.canals); canalDragRecorded = true }
                // Preserve the selected point's distance normal to this transverse plane.
                var q = p
                if !panoramic, let old = model.selectedCanal?.points[safe: model.selectedCanalPoint ?? -1]?.vector, let sample = renderedCurve?.samples[indices[cell]] {
                    let vertical = sample.sourceVertical ?? SIMD3(0,0,1)
                    let normal = sample.sourceNormal ?? SIMD3(sample.normal.x,sample.normal.y,0)
                    let tangent = simd_normalize(simd_cross(normal,vertical))
                    q += tangent*simd_dot(old-p,tangent)
                }
                model.moveCanalPoint(PatientPoint(q),record: false)
            }
        case .window, .arch: break
        }
        needsDisplay = true
    }
    func endDentalInteraction(at point: CGPoint) {
        defer { cancelMeasurement(); needsDisplay = true }
        guard dragTool == .measure, model.tool == .measure, measurementRevision == geometryRevision,
              let cell = dragCell, panoramic || (indices.indices.contains(cell) && indices[cell] == dragSection),
              let a = measureStart, let b = dentalImagePoint(point,cell: cell), let curve = renderedCurve, let v = renderedVolume else { return }
        if panoramic {
            let mm = PanoramicMeasurementGeometry.distance(a,b,curve: curve,verticalSpacing: v.spacing.z)
            if mm > 0.01 { model.panoramicMeasurements.append(PanoramicMeasurement(start: a,end: b,mm: mm)) }
        } else if let p = dentalPatientPoint(a,cell: cell), let q = dentalPatientPoint(b,cell: cell) {
            let mm = simd_distance(p,q)
            if mm > 0.01 { model.transverseMeasurements.append(TransverseMeasurement(section: indices[cell],start: a,end: b,mm: mm)) }
        }
    }
    func navigateDentalPoint(_ point: CGPoint, cell: Int) {
        guard let curve = renderedCurve, let v = renderedVolume, let patient = dentalPatientPoint(point,cell: cell) else { return }
        let original = renderedArchCurve ?? curve
        model.setArchDistance(original.distance(atColumn: panoramic ? point.x : Double(indices[cell])))
        let q = (patient-v.origin)/v.spacing
        model.x = min(Double(v.width-1),max(0,q.x)); model.y = min(Double(v.height-1),max(0,q.y)); model.z = min(Double(v.depth-1),max(0,q.z))
    }
    func drawTransverseMeasurements(in rect: CGRect, cell: Int) {
        guard let curve = renderedCurve, let v = renderedVolume, indices.indices.contains(cell) else { return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: cellRect(cell)).addClip()
        for m in model.transverseMeasurements where m.section == indices[cell] && imageRevision == model.archRevision {
            MeasurementOverlay.draw(from: dentalScreenPoint(m.start,cell: cell),to: dentalScreenPoint(m.end,cell: cell),mm: m.mm,bounds: cellRect(cell))
        }
        if dragCell == cell, dragTool == .measure, let a = measureStart, let b = measureEnd {
            let sample = curve.samples[indices[cell]]
            let mm = simd_distance(v.origin+curve.localPosition(sample: sample,height: a.y,offset: a.x),v.origin+curve.localPosition(sample: sample,height: b.y,offset: b.x))
            MeasurementOverlay.draw(from: dentalScreenPoint(a,cell: cell),to: dentalScreenPoint(b,cell: cell),mm: mm,bounds: cellRect(cell))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension DentalImagesView {
    func dentalProjection(_ point: SIMD3<Double>, cell: Int) -> CGPoint? {
        guard let curve = renderedCurve, let v = renderedVolume else { return nil }
        let local = point-v.origin
        if panoramic {
            let index = curve.samples.indices.min { a,b in
                func distance(_ i: Int) -> Double {
                    let sample = curve.samples[i], origin = sample.sourcePosition ?? SIMD3(sample.position.x,sample.position.y,local.z)
                    let vertical = sample.sourceVertical ?? SIMD3(0,0,1), delta = local-origin
                    return simd_length_squared(delta-vertical*simd_dot(delta,vertical))
                }
                return distance(a) < distance(b)
            }!
            let row = Double(v.depth-1)-curve.imageHeight(point: local,sample: curve.samples[index])/v.spacing.z
            return dentalScreenPoint(CGPoint(x: Double(index),y: row),cell: cell)
        }
        guard indices.indices.contains(cell) else { return nil }
        let sample = curve.samples[indices[cell]], origin = sample.sourcePosition ?? SIMD3(sample.position.x,sample.position.y,0)
        let normal = sample.sourceNormal ?? SIMD3(sample.normal.x,sample.normal.y,0)
        return dentalScreenPoint(CGPoint(x: simd_dot(local-origin,normal),y: curve.imageHeight(point: local,sample: sample)),cell: cell)
    }
    func dentalClippedSegment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, cell: Int, radius: Double) -> (SIMD3<Double>,SIMD3<Double>)? {
        if panoramic { return (a,b) }
        guard let curve = renderedCurve, let v = renderedVolume, indices.indices.contains(cell) else { return nil }
        let sample = curve.samples[indices[cell]], origin = sample.sourcePosition ?? SIMD3(sample.position.x,sample.position.y,0)
        let vertical = sample.sourceVertical ?? SIMD3(0,0,1), normal = sample.sourceNormal ?? SIMD3(sample.normal.x,sample.normal.y,0)
        return XelisOverlayGeometry.clipped(a,b,center: v.origin+origin,normal: simd_normalize(simd_cross(normal,vertical)),halfWidth: radius)
    }
    func dentalCanalHit(at point: CGPoint, cell: Int, segments: Bool) -> (UUID,Int)? {
        var nearest = 10.0, result: (UUID,Int)?
        for canal in model.planning.canals where canal.visible {
            if segments {
                let path = canal.path
                for i in 0..<max(0,path.points.count-1) {
                    guard let (a,b) = dentalClippedSegment(path.points[i],path.points[i+1],cell: cell,radius: canal.diameter/2),
                          let p = dentalProjection(a,cell: cell), let q = dentalProjection(b,cell: cell) else { continue }
                    let delta = SIMD2(q.x-p.x,q.y-p.y), offset = SIMD2(point.x-p.x,point.y-p.y)
                    let t = min(1,max(0,simd_dot(offset,delta)/max(1e-12,simd_length_squared(delta))))
                    let d = simd_length(offset-delta*t)
                    if d < nearest { nearest = d; result = (canal.id,i/path.subdivisions) }
                }
            } else {
                for (i,p) in canal.points.enumerated() {
                    guard dentalClippedSegment(p.vector,p.vector,cell: cell,radius: canal.diameter/2) != nil,
                          let q = dentalProjection(p.vector,cell: cell) else { continue }
                    let d = hypot(q.x-point.x,q.y-point.y)
                    if d < nearest { nearest = d; result = (canal.id,i) }
                }
            }
        }
        return result
    }
    func drawDentalPlanning(in rect: CGRect, cell: Int) {
        guard model.showPlanning, rect.width > 0, rect.height > 0 else { return }
        func segment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, radius: Double, color: NSColor) {
            guard let (a,b) = dentalClippedSegment(a,b,cell: cell,radius: radius), let p = dentalProjection(a,cell: cell), let q = dentalProjection(b,cell: cell) else { return }
            let line = NSBezierPath(); line.move(to: p); line.line(to: q); line.lineWidth = 2; color.setStroke(); line.stroke()
        }
        for canal in model.planning.canals where canal.visible {
            let rgb = canal.color.rgb, color = NSColor(calibratedRed: rgb.x,green: rgb.y,blue: rgb.z,alpha: 1)
            let path = canal.path
            for (a,b) in zip(path.points,path.points.dropFirst()) { segment(a,b,radius: canal.diameter/2,color: color) }
            for (i,point) in canal.points.enumerated() {
                guard dentalClippedSegment(point.vector,point.vector,cell: cell,radius: canal.diameter/2) != nil,
                      let p = dentalProjection(point.vector,cell: cell) else { continue }
                color.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x-3,y: p.y-3,width: 6,height: 6)).fill()
                if model.selectedCanalID == canal.id && model.selectedCanalPoint == i {
                    NSColor.white.setStroke(); NSBezierPath(ovalIn: CGRect(x: p.x-5,y: p.y-5,width: 10,height: 10)).stroke()
                }
            }
        }
        for implant in model.planning.implants {
            let color = implant.id == model.selectedImplantID ? NSColor.systemTeal : .systemBlue
            segment(implant.entry.vector,implant.apex,radius: implant.diameter/2,color: color)
            if dentalClippedSegment(implant.entry.vector,implant.entry.vector,cell: cell,radius: implant.diameter/2) != nil,
               let p = dentalProjection(implant.entry.vector,cell: cell) {
                color.setStroke(); let ring = NSBezierPath(ovalIn: CGRect(x: p.x-4,y: p.y-4,width: 8,height: 8)); ring.lineWidth = 2; ring.stroke()
                (implant.name as NSString).draw(at: CGPoint(x: p.x+7,y: p.y-15),withAttributes: [.font:NSFont.systemFont(ofSize: 10),.foregroundColor:color,.backgroundColor:NSColor.black.withAlphaComponent(0.7)])
            }
        }
    }
}
