import SwiftUI

enum ViewerWindowLayout {
    static let minimumContentSize = CGSize(width: 1080,height: 720)
}

enum ViewerPanel: String {
    case axial = "Axial", coronal = "Coronal", sagittal = "Sagital"
    case panoramic = "Panorámica curva", transverse = "Secciones transversales", volume = "Volumen 3D"
    init(plane: Plane) { switch plane { case .axial: self = .axial; case .coronal: self = .coronal; case .sagittal: self = .sagittal } }
}
struct PanelExpandButton: View {
    @ObservedObject var model: ViewerModel
    let panel: ViewerPanel
    var body: some View {
        Button { model.togglePanel(panel) } label: {
            Image(systemName: model.focusedPanel == panel ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }.buttonStyle(.borderless).controlSize(.small)
            .help(model.focusedPanel == panel ? "Volver a la distribución de paneles" : "Ampliar dentro del área de imágenes")
            .accessibilityLabel(model.focusedPanel == panel ? "Restaurar distribución" : "Ampliar \(panel.rawValue)")
    }
}
/// Resizes the same view in place, preserving zoom, pan, 3D rotation and in-progress view state.
struct PanelPresentation: ViewModifier {
    @ObservedObject var model: ViewerModel
    let panel: ViewerPanel
    let normal: CGRect
    let workspace: CGSize
    var visible: Bool { model.focusedPanel == nil || model.focusedPanel == panel }
    var rect: CGRect { model.focusedPanel == panel ? CGRect(origin: .zero,size: workspace) : normal }
    func body(content: Content) -> some View {
        content.frame(width: max(1,rect.width),height: max(1,rect.height))
            .offset(x: rect.minX,y: rect.minY).opacity(visible ? 1 : 0)
            .allowsHitTesting(visible).accessibilityHidden(!visible)
            .zIndex(model.focusedPanel == panel ? 1 : 0)
    }
}
