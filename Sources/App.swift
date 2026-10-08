import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ViewerModel()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Acerca de DentalViewer", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de DentalViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "Archivo"); fileItem.submenu = fileMenu
        let open = NSMenuItem(title: "Abrir estudio…", action: #selector(openStudy), keyEquivalent: "o"); open.target = self; fileMenu.addItem(open)
        let capture = NSMenuItem(title: "Guardar captura…", action: #selector(export), keyEquivalent: "s"); capture.target = self; fileMenu.addItem(capture)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DentalViewer"
        window.contentView = NSHostingView(rootView: ViewerRoot(model: model))
        // Apply after installing the hosting view, which supplies its own sizing constraints.
        window.contentMinSize = ViewerWindowLayout.minimumContentSize
        window.appearance = NSAppearance(named: .darkAqua)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--study"), index + 1 < args.count { model.open(URL(fileURLWithPath: args[index + 1])) }
        else if let last = UserDefaults.standard.string(forKey: "lastStudy"), FileManager.default.fileExists(atPath: last) { model.open(URL(fileURLWithPath: last)) }
        else {
            // Development bundle: discover a Data folder only alongside this project.
            let project = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let children = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil),
               let sample = children.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Xelis Dental Viewer/Data").path) }) {
                model.open(sample)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func openStudy() { model.openPanel() }
    @objc func export() { model.exportWindow() }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DentalViewer", .applicationVersion: "0.5.7", .credits: NSAttributedString(string: "Visor independiente para macOS.\nCT DICOM, MPR, 3D y trazados originales guardados en Xelis.\nPrototipo; no validado para diagnóstico ni cirugía.\nImportación parcial de proyectos Xelis; sin bibliotecas de implantes.")])
    }
}

@main enum DentalViewerApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
