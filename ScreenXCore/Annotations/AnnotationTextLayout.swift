import CoreGraphics
import CoreText
import Foundation

/// Text layout of text and note annotations, shared by `AnnotationRenderer` and the inline text editor,
/// so both use the same fonts, insets and Core Text measurement. Sizes are in original pixels.
public enum AnnotationTextLayout {
    /// Inset of the text inside a note.
    public static let notePadding: CGFloat = 16
    /// Note text size in points; in pixels it is `noteFontSize × originalScale`.
    public static let noteFontSize: CGFloat = 15
    public static let noteTextColor = ColorValue(hex: "#3A2F00")!

    /// Font and color of the string of a text or note annotation.
    public struct TextStyle: Equatable, Sendable {
        /// Font size in original pixels.
        public let fontSize: CGFloat
        public let bold: Bool
        public let color: ColorValue
    }

    /// The text style of a text or note annotation, `nil` for other kinds.
    /// `originalScale` is the capture's backing scale (note text is 15 pt).
    public static func textStyle(of a: Annotation, originalScale: CGFloat) -> TextStyle? {
        switch a.kind {
        case let .text(_, _, fontSize, bold, _):
            TextStyle(fontSize: CGFloat(fontSize), bold: bold, color: a.color)
        case .note:
            TextStyle(fontSize: noteFontSize * max(originalScale, 0.01), bold: false, color: noteTextColor)
        default:
            nil
        }
    }

    /// The rectangle the string is laid out in (unrotated): the frame of a text, the inset frame of a note.
    public static func textRect(of a: Annotation) -> CGRect? {
        switch a.kind {
        case let .text(frame, _, _, _, _): frame.standardized
        case let .note(frame, _, _): frame.standardized.insetBy(dx: notePadding, dy: notePadding)
        default: nil
        }
    }

    /// Height `string` needs when wrapped to `width`, as the renderer lays it out; at least one line,
    /// and a trailing line break counts as a started line.
    public static func textHeight(_ string: String, fontSize: CGFloat, bold: Bool, width: CGFloat) -> CGFloat {
        let measured = string.isEmpty || string.hasSuffix("\n") ? string + " " : string
        let size = measure(measured, font: systemFont(size: fontSize, bold: bold), width: width)
        return ceil(size.height) + 1
    }

    /// Frame height a text or note needs to show `string` (default: its own string) at its current width;
    /// `nil` for other kinds.
    public static func requiredFrameHeight(of a: Annotation, string: String? = nil,
                                           originalScale: CGFloat) -> CGFloat? {
        guard let style = textStyle(of: a, originalScale: originalScale), let rect = textRect(of: a) else {
            return nil
        }
        let text: String
        switch a.kind {
        case let .text(_, own, _, _, _), let .note(_, own, _): text = string ?? own
        default: return nil
        }
        let height = textHeight(text, fontSize: style.fontSize, bold: style.bold, width: rect.width)
        if case .note = a.kind { return height + 2 * notePadding }
        return height
    }

    // MARK: Core Text

    static func systemFont(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, max(size, 1), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, max(size, 1), nil)
    }

    static func attributed(_ string: String, font: CTFont, color: CGColor) -> CFAttributedString {
        NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]) as CFAttributedString
    }

    /// Size of `string` wrapped to `width`.
    static func measure(_ string: String, font: CTFont, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributed(string, font: font, color: CGColor(gray: 0, alpha: 1)))
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
    }
}
