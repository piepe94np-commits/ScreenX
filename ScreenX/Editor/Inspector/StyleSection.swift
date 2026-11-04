import ScreenXCore
import SwiftUI

/// Reiter „Stil“: Hintergrund, Rahmen, Format und Stil-Vorlagen.
struct StyleSection: View {
    let vm: EditorViewModel

    @State private var showsShadowDetails = false

    var body: some View {
        InspectorGroup(title: String(localized: "Hintergrund")) {
            BackgroundPicker(vm: vm)
        }
        InspectorGroup(title: String(localized: "Rahmen")) {
            frame
        }
        InspectorGroup(title: String(localized: "Format")) {
            format
        }
        InspectorGroup(title: String(localized: "Stil-Vorlagen")) {
            StylePresetMenu(vm: vm)
        }
    }

    // MARK: - Rahmen

    @ViewBuilder private var frame: some View {
        StyleSlider(vm: vm, title: String(localized: "Abstand"), range: 0...400,
                    actionName: String(localized: "Abstand"),
                    get: { $0.style.padding }, set: { $0.style.padding = $1 })
        StyleSlider(vm: vm, title: String(localized: "Ecken"), range: 0...60,
                    actionName: String(localized: "Ecken"),
                    get: { $0.style.cornerRadius }, set: { $0.style.cornerRadius = $1 })
        StyleSlider(vm: vm, title: String(localized: "Schatten"), range: 0...100,
                    actionName: String(localized: "Schatten"),
                    get: { $0.style.shadow.strength }, set: { $0.style.shadow.strength = $1 })

        DisclosureGroup(String(localized: "Schatten-Details"), isExpanded: $showsShadowDetails) {
            VStack(alignment: .leading, spacing: 10) {
                StyleSlider(vm: vm, title: String(localized: "Versatz"), range: 0...100,
                            actionName: String(localized: "Schatten-Versatz"),
                            get: { $0.style.shadow.resolved().offsetY },
                            set: { $0.style.shadow.offsetY = $1 })
                StyleSlider(vm: vm, title: String(localized: "Weichheit"), range: 0...200,
                            actionName: String(localized: "Schatten-Weichheit"),
                            get: { $0.style.shadow.resolved().blur },
                            set: { $0.style.shadow.blur = $1 })
                StyleSlider(vm: vm, title: String(localized: "Deckkraft %"), range: 0...100,
                            actionName: String(localized: "Schatten-Deckkraft"),
                            get: { $0.style.shadow.resolved().opacity * 100 },
                            set: { $0.style.shadow.opacity = $1 / 100 })
                Button(String(localized: "Automatisch")) {
                    vm.applyStyle(String(localized: "Schatten automatisch")) {
                        $0.style.shadow.offsetY = nil
                        $0.style.shadow.blur = nil
                        $0.style.shadow.opacity = nil
                    }
                }
                .disabled(isShadowAutomatic)
            }
            .padding(.top, 8)
        }

        // „Fensterschatten behalten“ ist in M2 ausgeblendet: Der Renderer kann den Systemschatten
        // noch nicht entfernen. Ob er im Bild ist, entscheidet die Einstellung „Fensterschatten aufnehmen“.
    }

    private var isShadowAutomatic: Bool {
        let shadow = vm.model.style.shadow
        return shadow.offsetY == nil && shadow.blur == nil && shadow.opacity == nil
    }

    // MARK: - Format

    @ViewBuilder private var format: some View {
        Picker(String(localized: "Format"), selection: Binding(
            get: { vm.model.style.aspect },
            set: { value in vm.applyStyle(String(localized: "Format")) { $0.style.aspect = value } }
        )) {
            ForEach(AspectRatio.allCases, id: \.self) { aspect in
                Text(Self.title(aspect)).tag(aspect)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        HStack(alignment: .top, spacing: 8) {
            Text("Position")
                .frame(width: 78, alignment: .leading)
            AlignmentGrid(selection: Binding(
                get: { vm.model.style.alignment },
                set: { value in vm.applyStyle(String(localized: "Position")) { $0.style.alignment = value } }))
            Spacer(minLength: 0)
        }
    }

    private static func title(_ aspect: AspectRatio) -> String {
        switch aspect {
        case .auto: String(localized: "Auto")
        case .r16x9: "16:9"
        case .r4x3: "4:3"
        case .r1x1: "1:1"
        case .r9x16: "9:16"
        case .r3x2: "3:2"
        }
    }
}
