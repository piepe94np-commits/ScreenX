import CoreGraphics
import ScreenXCore
import SwiftUI

/// Kleine Vorschaubilder der Vorlagen (Rahmengrafik), höchstens `maxPixelSide` Pixel je Seite.
/// Sie werden je Vorlage einmal erzeugt und aufbewahrt.
@MainActor
enum TemplateThumbnailCache {
    static let maxPixelSide: CGFloat = 160
    private static var images: [String: CGImage] = [:]

    /// Mitgelieferte Vorlagen werden als Vektorgrafik gezeichnet, eigene aus dem Vorlagenordner verkleinert.
    static func image(for template: DeviceTemplate) -> CGImage? {
        if let cached = images[template.id] { return cached }
        let longest = max(template.frameSize.width, template.frameSize.height)
        guard longest > 0 else { return nil }
        let scale = maxPixelSide / longest
        let image: CGImage?
        switch template.frame {
        case .builtin(let id):
            image = DeviceArtwork.image(builtin: id, scale: scale, urlText: nil)
        case .file:
            image = CustomTemplateStore.shared.image(for: template).flatMap { downscaled($0, scale: scale) }
        }
        if let image { images[template.id] = image }
        return image
    }

    private static func downscaled(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * min(scale, 1)).rounded()))
        let height = max(1, Int((CGFloat(image.height) * min(scale, 1)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
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
