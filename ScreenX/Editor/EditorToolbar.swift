import SwiftUI

/// Werkzeugleiste des Editors: Rückgängig/Wiederholen links, die Werkzeuge in der Mitte,
/// „Kopieren“ und „Sichern“ rechts.
struct EditorToolbar: ToolbarContent {
    let vm: EditorViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                vm.undo()
            } label: {
                Label("Widerrufen", systemImage: "arrow.uturn.backward")
            }
            .help("Widerrufen")
            .disabled(!vm.canUndo)

            Button {
                vm.redo()
            } label: {
                Label("Wiederholen", systemImage: "arrow.uturn.forward")
            }
            .help("Wiederholen")
            .disabled(!vm.canRedo)
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases, id: \.self) { tool in
                    ToolButton(tool: tool, isActive: vm.tool == tool) { vm.tool = tool }
                        .disabled(vm.isReadOnly && tool != .select)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Kopieren") {
                vm.copy()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Sichern") {
                vm.quickSave(settings: vm.settingsProvider())
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Ein Werkzeug-Button: Symbol über dem Namen, der aktive ist hervorgehoben. Der Tooltip nennt die Taste.
private struct ToolButton: View {
    let tool: EditorTool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        let tooltip = "\(tool.title) (\(tool.key))"
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 16)
                Text(tool.title)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .frame(minWidth: 46)
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background(isActive ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
