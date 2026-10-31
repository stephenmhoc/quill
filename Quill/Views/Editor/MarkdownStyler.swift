import SwiftUI

#if os(macOS)
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor

extension NSColor {
    static var quietText: NSColor { .tertiaryLabelColor }
    static var softText: NSColor { .secondaryLabelColor }
}
#else
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor

extension UIColor {
    static var quietText: UIColor { .tertiaryLabel }
    static var softText: UIColor { .secondaryLabel }
}
#endif

/// Quiet live styling. It only sets attributes: the text is always plain Markdown.
enum MarkdownStyler {
    #if os(macOS)
    /// Monospaced, because it reads as a draft in progress rather than finished type.
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: bodyFont)
    private static let textColor = NSColor.labelColor
    private static let boldFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
    private static let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    #else
    /// Monospaced, because it reads as a draft in progress rather than finished type.
    static let bodyFont: UIFont = {
        let size: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 18 : 16
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }()
    private static var lineHeight: CGFloat { bodyFont.lineHeight }
    private static let textColor = UIColor.label
    private static var boldFont: UIFont { font(.traitBold) }
    private static var italicFont: UIFont { font(.traitItalic) }

    private static func font(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        UIFont(descriptor: bodyFont.fontDescriptor.withSymbolicTraits(traits) ?? bodyFont.fontDescriptor, size: 0)
    }
    #endif

    static var base: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Line height of about 1.5: screens are read from further away than paper.
        paragraph.lineSpacing = max(0, bodyFont.pointSize * 1.5 - lineHeight)
        return [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    private static let heading = try! NSRegularExpression(pattern: "^#{1,6} .*$", options: .anchorsMatchLines)
    private static let quote = try! NSRegularExpression(pattern: "^> .*$", options: .anchorsMatchLines)
    private static let bold = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italic = try! NSRegularExpression(pattern: "(?<![*\\w])([*_])(?=[^\\s*_])(.+?)(?<=[^\\s*_])\\1(?![*\\w])")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let marker = try! NSRegularExpression(pattern: "^(#{1,6} |> |[-+*] |\\d+\\. )", options: .anchorsMatchLines)
    private static let linkTarget = try! NSRegularExpression(pattern: "(?<=\\])\\([^)\\n]*\\)")

    static func style(_ storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        let quiet = PlatformColor.quietText
        func each(_ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            pattern.enumerateMatches(in: storage.string, range: all) { match, _, _ in if let match { body(match) } }
        }
        storage.beginEditing()
        storage.setAttributes(base, range: all)
        each(heading) { storage.addAttribute(.font, value: boldFont, range: $0.range) }
        each(quote) { storage.addAttribute(.foregroundColor, value: PlatformColor.softText, range: $0.range) }
        each(bold) { match in
            storage.addAttribute(.font, value: boldFont, range: match.range)
            storage.addAttribute(.foregroundColor, value: quiet, range: match.range(at: 1))
            storage.addAttribute(.foregroundColor, value: quiet, range: NSRange(location: NSMaxRange(match.range) - match.range(at: 1).length, length: match.range(at: 1).length))
        }
        each(italic) { match in
            storage.addAttribute(.font, value: italicFont, range: match.range)
            storage.addAttribute(.foregroundColor, value: quiet, range: match.range(at: 1))
            storage.addAttribute(.foregroundColor, value: quiet, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }
        each(code) { storage.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.9, weight: .regular), range: $0.range) }
        each(marker) { storage.addAttribute(.foregroundColor, value: quiet, range: $0.range) }
        each(linkTarget) { storage.addAttribute(.foregroundColor, value: quiet, range: $0.range) }
        storage.endEditing()
    }
}
