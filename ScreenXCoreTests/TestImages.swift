import CoreGraphics

enum TestImages {
    static func solid(width: Int, height: Int, color: CGColor) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func gradient(width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)
        let space = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1)] as CFArray,
            locations: [0, 0.5, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return context.makeImage()!
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}
