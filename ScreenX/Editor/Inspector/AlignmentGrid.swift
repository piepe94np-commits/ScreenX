import ScreenXCore
import SwiftUI

/// 3×3-Punkteraster für die Position des Inhalts auf der Arbeitsfläche.
struct AlignmentGrid: View {
    @Binding var selection: ContentAlignment

    private static let columns = Array(repeating: GridItem(.fixed(20), spacing: 4), count: 3)

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 4) {
            // `allCases` ist zeilenweise geordnet: oben links … unten rechts.
            ForEach(ContentAlignment.allCases, id: \.self) { alignment in
                Button {
                    selection = alignment
                } label: {
                    Circle()
                        .fill(alignment == selection ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: alignment == selection ? 9 : 6, height: alignment == selection ? 9 : 6)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.title(alignment))
                .accessibilityLabel(Self.title(alignment))
                .accessibilityAddTraits(alignment == selection ? .isSelected : [])
            }
        }
        .frame(width: 68)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private static func title(_ alignment: ContentAlignment) -> String {
        switch alignment {
        case .topLeading: String(localized: "Oben links")
        case .top: String(localized: "Oben")
        case .topTrailing: String(localized: "Oben rechts")
        case .leading: String(localized: "Links")
        case .center: String(localized: "Mitte")
        case .trailing: String(localized: "Rechts")
        case .bottomLeading: String(localized: "Unten links")
        case .bottom: String(localized: "Unten")
        case .bottomTrailing: String(localized: "Unten rechts")
        }
    }
}
