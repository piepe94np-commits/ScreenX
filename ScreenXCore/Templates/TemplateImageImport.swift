import CoreGraphics
import Foundation
import ImageIO

/// Turns files dropped on the template creator into frame image data the `CustomTemplateStore` accepts.
public enum TemplateImageImport {
    /// Renders the first page of a PDF (crop box, page rotation applied) at `scale` pixels per point into a
    /// PNG with transparent background.
    /// - Throws: `TemplateError.unreadableImage` for data that is no PDF or has no drawable page,
    ///   `TemplateError.imageTooLarge` when a side would exceed `CustomTemplateStore.maxFrameSide`.
    public static func rasterizeFirstPage(pdfData: Data, scale: CGFloat = 2) throws -> Data {
        guard scale > 0, scale.isFinite,
              let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages >= 1,
              let page = document.page(at: 1)
        else { throw TemplateError.unreadableImage }
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        let pageSize = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        let width = (pageSize.width * scale).rounded(), height = (pageSize.height * scale).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { throw TemplateError.unreadableImage }
        guard width <= CustomTemplateStore.maxFrameSide, height <= CustomTemplateStore.maxFrameSide else {
            throw TemplateError.imageTooLarge
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TemplateError.unreadableImage }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // Maps the crop box (with the page's own rotation) onto the page-sized rect.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw TemplateError.unreadableImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString,
                                                                 1, nil)
        else { throw TemplateError.unreadableImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TemplateError.unreadableImage }
        return output as Data
    }
}
