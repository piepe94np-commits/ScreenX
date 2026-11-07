import Combine
import ScreenXCore
import SwiftUI

extension Notification.Name {
    /// Eigene Vorlagen wurden angelegt oder gelöscht; der Reiter „Vorlage“ lädt die Liste neu.
    static let customTemplatesDidChange = Notification.Name("com.screenx.app.customTemplatesDidChange")
}

/// Reiter „Vorlage“: Gerät wählen, Einpassen, URL des Browserfensters und Kippen.
/// Jede Änderung ist ein Undo-Schritt (`apply`), Regler ein Schritt je Zug.
struct TemplateSection: View {
    let vm: EditorViewModel

    @State private var customTemplates: [DeviceTemplate] = []
    /// Zuletzt gezeigte Variante je Gruppe, wenn die Vorlage des Dokuments nicht zur Gruppe gehört.
    @State private var chosenVariants: [String: String] = [:]
    @State private var urlDraft = ""
    @FocusState private var urlFocused: Bool
    @State private var colorEdit = ColorEditSession(remembersStyle: false)

    /// Eine Variante: ID der mitgelieferten Vorlage und kurzer Name.
    private struct Variant: Hashable {
        let id: String
        let label: String

        init(_ id: String, _ label: String) {
            self.id = id
            self.label = label
        }
    }

    /// Eine Gerätegruppe mit ihren Varianten.
    private struct DeviceGroup: Identifiable {
        let id: String
        let title: String
        let variants: [Variant]
    }

    private static let groups: [DeviceGroup] = [
        DeviceGroup(id: "laptop", title: String(localized: "Laptop"), variants: [
            Variant("laptop-silver", String(localized: "Silber")),
            Variant("laptop-black", String(localized: "Space-Schwarz")),
        ]),
        DeviceGroup(id: "monitor", title: String(localized: "Monitor"), variants: [
            Variant("monitor-silver", String(localized: "Silber")),
            Variant("monitor-black", String(localized: "Schwarz")),
        ]),
        DeviceGroup(id: "phone", title: String(localized: "Smartphone"), variants: [
            Variant("phone-portrait-light", String(localized: "Hoch, hell")),
            Variant("phone-portrait-dark", String(localized: "Hoch, dunkel")),
            Variant("phone-landscape-light", String(localized: "Quer, hell")),
            Variant("phone-landscape-dark", String(localized: "Quer, dunkel")),
        ]),
        DeviceGroup(id: "tablet", title: String(localized: "Tablet"), variants: [
            Variant("tablet-portrait-light", String(localized: "Hoch, hell")),
            Variant("tablet-portrait-dark", String(localized: "Hoch, dunkel")),
            Variant("tablet-landscape-light", String(localized: "Quer, hell")),
            Variant("tablet-landscape-dark", String(localized: "Quer, dunkel")),
        ]),
        DeviceGroup(id: "browser", title: String(localized: "Browser"), variants: [
            Variant("browser-light", String(localized: "Hell")),
            Variant("browser-dark", String(localized: "Dunkel")),
        ]),
    ]

    private static let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private static let customColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                                        GridItem(.flexible(), spacing: 8)]

    private var currentID: String? { vm.model.template?.templateID }

    var body: some View {
        if vm.isTemplateMissing {
            MissingTemplateHint()
                .padding(12)
        }
        InspectorGroup(title: String(localized: "Gerät")) {
            deviceGrid
            if let hint = aspectHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        InspectorGroup(title: String(localized: "Eigene")) {
            customGrid
        }
        if let template = vm.resolvedTemplate, let placement = vm.model.template {
            InspectorGroup(title: String(localized: "Einpassen")) {
                fitControls(placement)
            }
            if Self.isBrowser(template) {
                InspectorGroup(title: String(localized: "Adresse")) {
                    urlField
                }
            }
        }
        InspectorGroup(title: String(localized: "Kippen")) {
            TiltControl(vm: vm)
        }
        .onAppear { reloadCustomTemplates() }
        .onReceive(NotificationCenter.default.publisher(for: .customTemplatesDidChange)) { _ in
            reloadCustomTemplates()
        }
    }

    // MARK: - Geräte

    private var deviceGrid: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
            VStack(spacing: 4) {
                TemplateThumbnail(title: String(localized: "Ohne Gerät"), image: nil,
                                  isSelected: vm.model.template == nil) { select(nil) }
                // Gleiche Höhe wie die Variantenauswahl der Gruppen.
                Color.clear.frame(height: 20)
            }
            ForEach(Self.groups) { group in
                groupCell(group)
            }
        }
    }

    private func groupCell(_ group: DeviceGroup) -> some View {
        let shownID = shownVariant(of: group)
        let isSelected = group.variants.contains { $0.id == currentID }
        return VStack(spacing: 4) {
            TemplateThumbnail(title: group.title,
                              image: TemplateCatalog.builtin(id: shownID).flatMap(TemplateThumbnailCache.image(for:)),
                              isSelected: isSelected) { select(shownID) }
            Picker(group.title, selection: Binding(
                get: { shownID },
                set: { id in
                    chosenVariants[group.id] = id
                    select(id)
                })) {
                ForEach(group.variants, id: \.id) { variant in
                    Text(variant.label).tag(variant.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.mini)
            .frame(height: 20)
        }
    }

    /// Variante, die die Kachel zeigt: die des Dokuments, sonst die zuletzt gewählte, sonst die erste.
    private func shownVariant(of group: DeviceGroup) -> String {
        if let currentID, group.variants.contains(where: { $0.id == currentID }) { return currentID }
        return chosenVariants[group.id] ?? group.variants[0].id
    }

    // MARK: - Eigene Vorlagen

    @ViewBuilder private var customGrid: some View {
        if customTemplates.isEmpty {
            Text("Noch keine eigenen Vorlagen.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: Self.customColumns, alignment: .leading, spacing: 10) {
                ForEach(customTemplates) { template in
                    TemplateThumbnail(title: template.name, image: TemplateThumbnailCache.image(for: template),
                                      symbolName: "photo", isSelected: currentID == template.id) {
                        select(template.id)
                    }
                }
            }
        }
        if let create = vm.onCreateCustomTemplate {
            Button(String(localized: "+ Eigene Vorlage …")) { create() }
        }
    }

    private func reloadCustomTemplates() {
        customTemplates = CustomTemplateStore.shared.all()
    }

    // MARK: - Einpassen

    @ViewBuilder private func fitControls(_ placement: TemplatePlacement) -> some View {
        Picker(String(localized: "Einpassen"), selection: Binding(
            get: { placement.fit },
            set: { fit in vm.apply(String(localized: "Einpassen")) { $0.template?.fit = fit } }
        )) {
            Text("Füllen").tag(FitMode.fill)
            Text("Einpassen").tag(FitMode.fit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch placement.fit {
        case .fit:
            ColorPicker(String(localized: "Füllfarbe"), selection: fillColor, supportsOpacity: false)
        case .fill:
            let free = freeFillRange
            OffsetSlider(vm: vm, title: String(localized: "Ausschnitt X"), isMovable: free.width > 0.5,
                         get: { $0.template?.offset.x ?? 0 }, set: { $0.template?.offset.x = $1 })
            OffsetSlider(vm: vm, title: String(localized: "Ausschnitt Y"), isMovable: free.height > 0.5,
                         get: { $0.template?.offset.y ?? 0 }, set: { $0.template?.offset.y = $1 })
        }
    }

    /// Freier Spielraum des Ausschnitts beim Füllen in Pixeln des Inhalts (je Achse; 0 = nichts zu verschieben).
    private var freeFillRange: CGSize {
        guard let template = vm.resolvedTemplate else { return .zero }
        let content = vm.contentSize
        let source = TemplateGeometry.sourceRect(contentSize: content, screenSize: template.screenBounds.size,
                                                 fit: .fill, offset: .zero).source
        return CGSize(width: content.width - source.width, height: content.height - source.height)
    }

    private var fillColor: Binding<CGColor> {
        Binding(
            get: { vm.model.template?.fillColor.cgColor ?? .black },
            set: { color in
                guard let value = ColorValue(converting: color) else { return }
                colorEdit.change(vm, String(localized: "Füllfarbe")) { $0.template?.fillColor = value }
            })
    }

    /// „Für dieses Gerät besser im Format … aufnehmen.“, wenn das Seitenverhältnis um mehr als 15 % abweicht.
    private var aspectHint: String? {
        guard let template = vm.resolvedTemplate, let preferred = template.preferredAspect,
              let mismatch = TemplateGeometry.aspectMismatch(contentSize: vm.contentSize, preferred: preferred),
              mismatch > 0.15
        else { return nil }
        let format = TemplateGeometry.recommendedAspectText(preferred)
        return String(localized: "Für dieses Gerät besser im Format \(format) aufnehmen.")
    }

    // MARK: - Browser

    private static func isBrowser(_ template: DeviceTemplate) -> Bool {
        if case .builtin(let id) = template.frame { return id.hasPrefix("browser-") }
        return false
    }

    private var urlField: some View {
        TextField(String(localized: "Adresse"), text: $urlDraft, prompt: Text(verbatim: DeviceArtwork.defaultURLText))
            .labelsHidden()
            .focused($urlFocused)
            .onSubmit { commitURL() }
            .onChange(of: urlFocused) { _, focused in if !focused { commitURL() } }
            .onAppear { urlDraft = vm.model.template?.urlText ?? "" }
            // Reiterwechsel bzw. Schließen des Fensters: der Entwurf geht nicht verloren.
            .onDisappear { commitURL() }
            .onChange(of: vm.model.template?.urlText) { _, text in
                if !urlFocused { urlDraft = text ?? "" }
            }
    }

    /// Übernimmt das Textfeld als ein Undo-Schritt; leer heißt Standardadresse.
    private func commitURL() {
        let text = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = text.isEmpty ? nil : text
        guard vm.model.template != nil, vm.model.template?.urlText != value else { return }
        vm.apply(String(localized: "Adresse")) { $0.template?.urlText = value }
    }

    // MARK: - Auswahl

    /// Wechselt die Vorlage (ein Undo-Schritt); Einpassen, Füllfarbe, Ausschnitt und Adresse bleiben.
    private func select(_ id: String?) {
        guard id != currentID else { return }
        colorEdit.finish(vm)
        vm.selectTemplate(id: id)
    }
}

/// Gelber Hinweis, wenn die Vorlage des Dokuments fehlt (Spec §8).
struct MissingTemplateHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Vorlage nicht gefunden – Screenshot wird ohne Gerät gezeigt.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    /// Als Leiste über der Arbeitsfläche (wie der Hinweis „nur Ansicht“).
    func banner() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.2))
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// Regler für den Ausschnitt beim Füllen (−1 … 1, 0 = mittig). Ein Zug ist ein Undo-Schritt;
/// „Mitte“ setzt ihn zurück (ebenfalls ein Schritt). Ohne freien Spielraum (`isMovable` false) ist der Regler
/// deaktiviert; „Mitte“ bleibt nutzbar, falls noch ein Wert gespeichert ist.
private struct OffsetSlider: View {
    let vm: EditorViewModel
    let title: String
    let isMovable: Bool
    let get: (DocumentModel) -> CGFloat
    let set: (inout DocumentModel, CGFloat) -> Void

    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: -1...1, onEditingChanged: { editing in
                isEditing = editing
                if editing {
                    vm.beginContinuousChange()
                } else {
                    vm.endContinuousChange(String(localized: "Ausschnitt"))
                }
            })
            .disabled(!isMovable)
            Button(String(localized: "Mitte")) {
                vm.apply(String(localized: "Ausschnitt")) { set(&$0, 0) }
            }
            .disabled(get(vm.model) == 0)
        }
    }

    private var value: Binding<Double> {
        Binding(
            get: { Double(get(vm.model)) },
            set: { newValue in
                if isEditing {
                    vm.applyLive { set(&$0, CGFloat(newValue)) }
                } else {
                    // Tastatur oder Bedienungshilfen: ohne Reglerzug ein einzelner Schritt.
                    vm.apply(String(localized: "Ausschnitt")) { set(&$0, CGFloat(newValue)) }
                }
            })
    }
}
