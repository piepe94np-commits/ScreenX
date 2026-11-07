import AppKit
import ScreenXCore
import SwiftUI

/// Aufbau des Editor-Fensters: Arbeitsfläche links, Inspektor (300 pt) rechts,
/// Werkzeugleiste in der Titelleiste.
struct EditorView: View {
    let vm: EditorViewModel
    @Binding var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ToolOptionsBar(vm: vm)
                if vm.isReadOnly { readOnlyBanner }
                if vm.isTemplateMissing { MissingTemplateHint().banner() }
                CanvasView(vm: vm)
            }
            Divider()
            InspectorView(vm: vm, settings: $settings)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Color.editorInspector)
        }
        .toolbar { EditorToolbar(vm: vm) }
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Mit einer neueren ScreenX-Version erstellt – nur Ansicht.")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.2))
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension Color {
    /// Hintergrund der Arbeitsfläche: #ECECF0 hell, Systemfarbe dunkel.
    static let editorCanvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .underPageBackgroundColor
            : NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xF0 / 255, alpha: 1)
    })

    /// Hintergrund des Inspektors: #FBFBFD hell, Fensterhintergrund dunkel.
    static let editorInspector = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xFD / 255, alpha: 1)
    })
}
