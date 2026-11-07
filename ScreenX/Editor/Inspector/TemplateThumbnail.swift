import CoreGraphics
import ImageIO
import ScreenXCore
import SwiftUI

/// Kleine Vorschaubilder der Vorlagen (Rahmengrafik). Sie werden je Vorlage einmal erzeugt und aufbewahrt,
/// auch wenn keins entsteht (z. B. fehlendes Bild), damit die Liste das Bild nicht bei jedem Zeichnen liest.
@MainActor
enum TemplateThumbnailCache {
    /// Mitgelieferte Vorlagen: längste Seite in Pixeln.
    static let maxPixelSide: CGFloat = 160
    /// Eigene Vorlagen: längste Seite des von ImageIO erzeugten Vorschaubilds.
    static let maxCustomPixelSide = 320
    private static var images: [String: CGImage?] = [:]

    /// Mitgelieferte Vorlagen werden als Vektorgrafik gezeichnet, eigene als Vorschaubild ihrer Bilddatei
    /// (`frameData`, sonst aus dem Vorlagenordner), ohne das ganze Bild zu dekodieren.
    static func image(for template: DeviceTemplate, frameData: Data? = nil) -> CGImage? {
        if let cached = images[template.id] { return cached }
        let image: CGImage?
        switch template.frame {
        case .builtin(let id):
            let longest = max(template.frameSize.width, template.frameSize.height)
            image = longest > 0 ? DeviceArtwork.image(builtin: id, scale: maxPixelSide / longest, urlText: nil) : nil
        case .file:
            image = (frameData ?? CustomTemplateStore.shared.imageData(for: template)).flatMap(thumbnail)
        }
        images[template.id] = .some(image) // also a miss (`nil` would remove the key)
        return image
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxCustomPixelSide,
            // Wie Vorlagenordner und Renderer: Pixel ohne EXIF-Ausrichtung.
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Eine Kachel im Vorlagen-Raster: Vorschaubild (bzw. Symbol) über dem Namen, die gewählte ist hervorgehoben.
struct TemplateThumbnail: View {
    let title: String
    /// `nil` zeigt `symbolName` (z. B. für „Ohne Gerät“).
    let image: CGImage?
    var symbolName = "rectangle.dashed"
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
