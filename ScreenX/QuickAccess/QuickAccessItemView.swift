import AppKit
import SwiftUI
import ScreenXCore

/// Maße der Schnellzugriffs-Karte (Figma „Schnellzugriff nach Aufnahme“).
enum QuickAccessMetrics {
    static let cardSize = CGSize(width: 260, height: 190)
    /// Transparenter Rand ums Panel, in dem der Kartenschatten gezeichnet wird.
    /// Oben höchstens so groß wie der Stapelabstand, damit keine Karte darüber verdeckt wird.
    static let margins = NSEdgeInsets(top: 12, left: 28, bottom: 40, right: 28)
    static let panelSize = CGSize(
        width: cardSize.width + margins.left + margins.right,
        height: cardSize.height + margins.top + margins.bottom
    )
}

enum QuickAccessFeedback {
    case copied
    case saved
}

/// Zustand einer Karte, beobachtet von `QuickAccessItemView`.
@MainActor @Observable
final class QuickAccessItemModel {
    let capture: Capture
    let thumbnail: NSImage
    var isHovered = false
    var isPinned = false
    var feedback: QuickAccessFeedback?

    init(capture: Capture) {
        self.capture = capture
        let size = NSSize(
            width: CGFloat(capture.image.width) / capture.scale,
            height: CGFloat(capture.image.height) / capture.scale
        )
        thumbnail = NSImage(cgImage: capture.image, size: size)
    }
}

/// Aktionen einer Karte; `edit == nil` blendet „Bearbeiten“ aus.
struct QuickAccessActions {
    var copy: () -> Void
    var save: () -> Void
    var edit: (() -> Void)?
    var close: () -> Void
    var togglePin: () -> Void
    var makeDragFile: () throws -> URL
    var dragEnded: (_ dropped: Bool) -> Void
}

struct QuickAccessItemView: View {
    let model: QuickAccessItemModel
    let actions: QuickAccessActions

    var body: some View {
        card
            .frame(width: QuickAccessMetrics.cardSize.width, height: QuickAccessMetrics.cardSize.height)
            .padding(EdgeInsets(
                top: QuickAccessMetrics.margins.top,
                leading: QuickAccessMetrics.margins.left,
                bottom: QuickAccessMetrics.margins.bottom,
                trailing: QuickAccessMetrics.margins.right
            ))
            .animation(.easeOut(duration: 0.15), value: model.isHovered)
            .animation(.easeOut(duration: 0.15), value: model.feedback)
    }

    private var card: some View {
        thumbnail
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 16)
            )
            .overlay(alignment: .topLeading) {
                if model.isHovered {
                    circleButton("xmark", label: String(localized: "Schließen"), action: actions.close)
                        .padding(6)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isHovered || model.isPinned {
                    circleButton(
                        model.isPinned ? "pin.fill" : "pin",
                        label: model.isPinned ? String(localized: "Lösen") : String(localized: "Anheften"),
                        action: actions.togglePin
                    )
                    .padding(6)
                    .transition(.opacity)
                }
            }
    }

    private var thumbnail: some View {
        Image(nsImage: model.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                ThumbnailDragView(
                    image: model.thumbnail,
                    makeFile: actions.makeDragFile,
                    onClick: actions.edit,
                    onDragEnded: actions.dragEnded
                )
            }
            .overlay {
                if model.isHovered || model.feedback != nil {
                    Color.black.opacity(0.45)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { hoverContent }
    }

    @ViewBuilder
    private var hoverContent: some View {
        if let feedback = model.feedback {
            feedbackLabel(feedback)
                .transition(.opacity)
        } else if model.isHovered {
            VStack(spacing: 6) {
                actionButton(String(localized: "Kopieren"), action: actions.copy)
                actionButton(String(localized: "Sichern"), action: actions.save)
                if let edit = actions.edit {
                    actionButton(String(localized: "Bearbeiten"), action: edit)
                }
            }
            .transition(.opacity)
        }
    }

    private func feedbackLabel(_ feedback: QuickAccessFeedback) -> some View {
        let text = switch feedback {
        case .copied: String(localized: "Kopiert")
        case .saved: String(localized: "Gesichert")
        }
        return VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 120, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Hosting-View mit eigener Hover-Erkennung über der Kartenfläche.
/// `.activeAlways`, weil ScreenX beim Anzeigen nie aktiv ist (das Panel aktiviert die App nicht).
final class QuickAccessHostingView: NSHostingView<QuickAccessItemView> {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(true) } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(false) } else { super.mouseExited(with: event) }
    }

    private var cardRect: CGRect {
        let margins = QuickAccessMetrics.margins
        return CGRect(
            x: margins.left,
            y: isFlipped ? margins.top : margins.bottom,
            width: QuickAccessMetrics.cardSize.width,
            height: QuickAccessMetrics.cardSize.height
        )
    }
}
