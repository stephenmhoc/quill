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
    /// View > Zoom In and Zoom Out change this, and it's kept for every entry.
    static let textSizeKey = "editorTextSize"
    static let defaultTextSize: Double = 15
    static let textSizes: ClosedRange<Double> = 10...36
    static var textSize: Double {
        let saved = UserDefaults.standard.double(forKey: textSizeKey)
        return saved > 0 ? min(max(saved, textSizes.lowerBound), textSizes.upperBound) : defaultTextSize
    }

    private struct Fonts {
        let size: Double
        let body: NSFont
        let bold: NSFont
        let italic: NSFont
        let lineHeight: CGFloat

        init(size: Double) {
            self.size = size
            // Monospaced, because it reads as a draft in progress rather than finished type.
            body = .monospacedSystemFont(ofSize: size, weight: .regular)
            bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
            italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
            lineHeight = NSLayoutManager().defaultLineHeight(for: body)
        }
    }

    private static var cached = Fonts(size: defaultTextSize)
    private static var fonts: Fonts {
        if cached.size != textSize { cached = Fonts(size: textSize) }
        return cached
    }

    static var bodyFont: NSFont { fonts.body }
    private static var lineHeight: CGFloat { fonts.lineHeight }
    private static let textColor = NSColor.labelColor
    private static var boldFont: NSFont { fonts.bold }
    private static var italicFont: NSFont { fonts.italic }
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

    /// Every pattern stays within a line, so an edit only needs its own paragraphs restyled.
    static func style(_ storage: NSTextStorage, around edited: NSRange? = nil) {
        let length = storage.length
        let all: NSRange = if let edited {
            (storage.string as NSString).paragraphRange(for: NSRange(location: min(edited.location, length),
                                                                     length: min(edited.length, length - min(edited.location, length))))
        } else {
            NSRange(location: 0, length: length)
        }
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
