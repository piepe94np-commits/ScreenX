import AppKit
import ScreenXCore
import SwiftUI

/// Arbeitsfläche: zeigt die gerenderte Vorschau eingepasst oder in festen Zoomstufen mit Scrollen.
/// Über der Vorschau liegt die Interaktionsschicht für Anmerkungen. Unten links Zoom-Steuerung,
/// Ausgabegröße und ein Griff, mit dem sich das fertige Bild als Datei herausziehen lässt.
struct CanvasView: View {
    let vm: EditorViewModel

    /// `nil` = Einpassen. 100 % zeigt die Aufnahme in ihrer Punktgröße.
    @State private var zoomPercent: Int?
    @Environment(\.displayScale) private var displayScale

    private static let zoomLevels = [50, 100, 200, 400]
    private static let margin: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let scale = pointsPerPixel(viewport: geo.size)
            let size = CGSize(width: vm.displaySize.width * scale, height: vm.displaySize.height * scale)
            ScrollView([.horizontal, .vertical]) {
                canvas(size: size, scale: scale)
                    .frame(width: max(size.width + 2 * Self.margin, geo.size.width),
                           height: max(size.height + 2 * Self.margin, geo.size.height))
            }
            .scrollIndicators(zoomPercent == nil ? .hidden : .automatic)
            .onChange(of: CGSize(width: size.width * displayScale, height: size.height * displayScale),
                      initial: true) { _, pixels in
                vm.renderPreview(maxPixelSize: pixels)
            }
            .overlay(alignment: .bottomLeading) {
                footer(currentPercent: Int((scale * vm.captureScale * 100).rounded()))
                    .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                if let notice = vm.notice {
                    Text(notice)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.notice)
        }
        .background(Color.editorCanvas)
    }

    // MARK: - Fläche

    private func canvas(size: CGSize, scale: CGFloat) -> some View {
        ZStack {
            // Schachbrett nur innerhalb der Fläche: sichtbar, wo das Bild transparent ist.
            Image(nsImage: Self.checkerTile)
                .resizable(resizingMode: .tile)
            if vm.renderFailed {
                Label("Das Bild konnte nicht erzeugt werden.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            } else if let preview = vm.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            AnnotationInteraction(
                vm: vm, mapping: vm.canvasMapping(viewScale: scale), viewScale: scale,
                annotations: vm.model.annotations, selection: vm.selection, tool: vm.tool,
                editingTextID: vm.editingTextID, cropDraft: vm.cropDraft)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Punkte je Pixel des Originals für die aktuelle Zoomstufe. Einpassen vergrößert nie über 100 %.
    private func pointsPerPixel(viewport: CGSize) -> CGFloat {
        let canvas = vm.displaySize
        guard canvas.width > 0, canvas.height > 0 else { return 0 }
        let actualSize = 1 / vm.captureScale
        if let zoomPercent { return actualSize * CGFloat(zoomPercent) / 100 }
        let fit = min((viewport.width - 2 * Self.margin) / canvas.width,
                      (viewport.height - 2 * Self.margin) / canvas.height)
        return max(0.01, min(actualSize, fit))
    }

    // MARK: - Zoom und Ausgabegröße

    private func footer(currentPercent: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    if let lower = Self.zoomLevels.last(where: { $0 < currentPercent }) { zoomPercent = lower }
                } label: {
                    Image(systemName: "minus")
                }
                .help("Verkleinern")
                .disabled(currentPercent <= Self.zoomLevels[0])

                Menu {
                    Button("Einpassen") { zoomPercent = nil }
                    Divider()
                    ForEach(Self.zoomLevels, id: \.self) { level in
                        Button(Self.percentText(level)) { zoomPercent = level }
                    }
                } label: {
                    Text(zoomPercent == nil ? String(localized: "Einpassen") : Self.percentText(currentPercent))
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    if let higher = Self.zoomLevels.first(where: { $0 > currentPercent }) { zoomPercent = higher }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Vergrößern")
                .disabled(currentPercent >= Self.zoomLevels[Self.zoomLevels.count - 1])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())

            Text(sizeText)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let preview = vm.preview {
                dragHandle(preview)
            }
        }
    }

    /// Ziehen am Symbol übergibt das exportierte Bild als Datei (die Fläche selbst gehört den Werkzeugen).
    private func dragHandle(_ preview: CGImage) -> some View {
        let side: CGFloat = 22
        return Image(systemName: "square.and.arrow.up")
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                ThumbnailDragView(
                    image: NSImage(cgImage: preview, size: Self.fitted(preview, side: side)),
                    makeFile: { try vm.makeDragFile() },
                    onClick: nil,
                    onDragEnded: { _ in })
            }
            .help("Ziehen, um das Bild als Datei abzulegen")
            .accessibilityLabel(String(localized: "Bild herausziehen"))
    }

    /// Größe für das Zieh-Vorschaubild: in `side` × `side` eingepasst, Seitenverhältnis bleibt.
    private static func fitted(_ image: CGImage, side: CGFloat) -> NSSize {
        let width = CGFloat(max(image.width, 1)), height = CGFloat(max(image.height, 1))
        let scale = side / max(width, height)
        return NSSize(width: max(1, width * scale), height: max(1, height * scale))
    }

    private var sizeText: String {
        let size = vm.exportPixelSize(vm.settingsProvider())
        return String(localized: "\(size.width) × \(size.height) px")
    }

    private static func percentText(_ percent: Int) -> String {
        (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// 16×16-Kachel, vorab gezeichnet (kein Zeichen-Block, den AppKit später abseits des Main Actors aufruft).
    @MainActor private static let checkerTile: NSImage = {
        let size = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: NSSize(width: size, height: size)) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        guard let tile = context.makeImage() else { return NSImage(size: NSSize(width: size, height: size)) }
        return NSImage(cgImage: tile, size: NSSize(width: size, height: size))
    }()
}
