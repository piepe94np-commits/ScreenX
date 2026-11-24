import AppKit
import ScreenXCore
import SwiftUI
import UniformTypeIdentifiers

/// Hintergrund: Verlauf (Vorlagen und eigener Verlauf), Farbe, Bild, unscharfer Screenshot oder keiner.
struct BackgroundPicker: View {
    let vm: EditorViewModel

    private enum Kind: Hashable { case gradient, solid, image, blurred, none }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    private static let columns = Array(repeating: GridItem(.fixed(34), spacing: 10), count: 6)

    /// „Bild“ ist gewählt, aber noch kein Bild geladen; das Modell bleibt bis dahin unverändert.
    @State private var pendingImage = false
    @State private var colorEdit = ColorEditSession()

    private var kind: Kind {
        pendingImage ? .image : modelKind
    }

    private var modelKind: Kind {
        switch vm.model.style.background {
        case .gradient: return .gradient
        case .solid: return .solid
        case .image: return .image
        case .blurredScreenshot: return .blurred
        case .none: return .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(String(localized: "Hintergrund"), selection: Binding(get: { kind }, set: { select($0) })) {
                Text("Verlauf").tag(Kind.gradient)
                Text("Farbe").tag(Kind.solid)
                Text("Bild").tag(Kind.image)
                Text("Unscharf").tag(Kind.blurred)
                Text("Keiner").tag(Kind.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .gradient:
                presets
                GradientEditor(vm: vm, colorEdit: colorEdit)
            case .solid:
                ColorPicker(String(localized: "Farbe"), selection: solidColor, supportsOpacity: false)
            case .image:
                imageArea
            case .blurred:
                StyleSlider(vm: vm, title: String(localized: "Stärke"), range: 5...100,
                            actionName: String(localized: "Unschärfe"),
                            get: { model in
                                if case let .blurredScreenshot(radius) = model.style.background { return radius }
                                return 40
                            },
                            set: { $0.style.background = .blurredScreenshot(radius: $1) })
            case .none:
                EmptyView()
            }
        }
        .onChange(of: vm.model.style.background) { pendingImage = false }
    }

    private func select(_ newKind: Kind) {
        pendingImage = false
        guard newKind != modelKind else { return }
        colorEdit.finish(vm)
        let background: Background
        switch newKind {
        case .gradient:
            background = GradientPresets.all[0]
        case .solid:
            var color = ColorValue(red: 1, green: 1, blue: 1)
            if case let .gradient(stops, _) = vm.model.style.background, let first = stops.first {
                color = first.color
            }
            background = .solid(color)
        case .image:
            guard let ext = vm.backgroundExtension, vm.backgroundImage != nil else {
                pendingImage = true
                return
            }
            background = .image(file: "background.\(ext)")
        case .blurred:
            background = .blurredScreenshot(radius: 40)
        case .none:
            background = .none
        }
        vm.applyStyle(String(localized: "Hintergrund")) { $0.style.background = background }
    }

    // MARK: - Verlauf

    private var presets: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
            ForEach(GradientPresets.all.indices, id: \.self) { index in
                let preset = GradientPresets.all[index]
                let selected = vm.model.style.background == preset
                Button {
                    colorEdit.finish(vm)
                    vm.applyStyle(String(localized: "Verlauf")) { $0.style.background = preset }
                } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(preset.swiftUIGradient ?? LinearGradient(colors: [], startPoint: .top, endPoint: .bottom))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .padding(-4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Verlauf \(index + 1)"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
    }

    // MARK: - Farbe

    private var solidColor: Binding<CGColor> {
        Binding(
            get: {
                if case let .solid(color) = vm.model.style.background { return color.cgColor }
                return .white
            },
            set: { cgColor in
                guard let color = ColorValue(converting: cgColor) else { return }
                colorEdit.change(vm, String(localized: "Hintergrundfarbe")) { $0.style.background = .solid(color) }
            })
    }

    // MARK: - Bild

    private var imageArea: some View {
        VStack(spacing: 8) {
            if let image = vm.backgroundImage, case .image = vm.model.style.background {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Bild hierher ziehen")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            Button(String(localized: "Bild wählen …"), action: chooseImage)
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Nur lokale Dateien; nichts aus dem Netz auf dem Main Actor laden.
            guard let url = urls.first, url.isFileURL else { return false }
            return loadImage(url)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(url)
    }

    /// Lädt das Bild als Hintergrund; `false` (mit Hinweisfenster), wenn es nicht geht.
    @discardableResult
    private func loadImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        do {
            guard Self.imageExtensions.contains(ext) else { throw EditorError.unreadableImage }
            let data = try Data(contentsOf: url)
            colorEdit.finish(vm)
            try vm.setBackgroundImage(data: data, ext: ext)
            vm.rememberStyle()
            return true
        } catch {
            EditorViewModel.present(error)
            return false
        }
    }
}

extension Background {
    /// Verlauf als SwiftUI-Füllung (Winkel nach CSS: 0° nach oben, 90° nach rechts).
    var swiftUIGradient: LinearGradient? {
        guard case let .gradient(stops, angle) = self else { return nil }
        let radians = angle * .pi / 180
        let dx = sin(radians) / 2
        let dy = -cos(radians) / 2
        return LinearGradient(
            stops: stops.map { Gradient.Stop(color: Color(cgColor: $0.color.cgColor), location: $0.location) },
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}
