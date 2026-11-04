import Foundation

/// Die Werkzeuge des Editors. Jedes hat eine Taste ohne Modifier, ein SF-Symbol und einen deutschen Namen.
enum EditorTool: CaseIterable {
    case select, arrow, shape, text, note, counter, blur, highlight, crop

    /// Taste, die das Werkzeug ohne Modifier wählt (Großbuchstabe, wie im Tooltip).
    var key: Character {
        switch self {
        case .select: "V"
        case .arrow: "A"
        case .shape: "R"
        case .text: "T"
        case .note: "N"
        case .counter: "C"
        case .blur: "B"
        case .highlight: "H"
        case .crop: "K"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .shape: "square.on.circle"
        case .text: "textformat"
        case .note: "note.text"
        case .counter: "1.circle"
        case .blur: "drop.halffull"
        case .highlight: "highlighter"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: String(localized: "Auswahl")
        case .arrow: String(localized: "Pfeil")
        case .shape: String(localized: "Form")
        case .text: String(localized: "Text")
        case .note: String(localized: "Notiz")
        case .counter: String(localized: "Zähler")
        case .blur: String(localized: "Unschärfe")
        case .highlight: String(localized: "Marker")
        case .crop: String(localized: "Zuschnitt")
        }
    }

    /// Das Werkzeug zur Taste `character` (Groß- und Kleinschreibung egal), sonst `nil`.
    init?(key character: Character) {
        let upper = character.uppercased()
        guard let tool = Self.allCases.first(where: { String($0.key) == upper }) else { return nil }
        self = tool
    }
}
