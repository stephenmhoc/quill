import Foundation

/// Turns what the user wrote into an `OutgoingPost`.
///
/// Ghost requires a title and turns an empty one into "(Untitled)" with a colliding
/// `untitled` slug. An untitled entry is therefore sent with its date and time as the
/// title, plus the internal tag `#untitled` so themes can hide the title.
public enum EntryBuilder {
    public static let untitledTag = "#untitled"

    public static func post(
        title: String,
        markdown: String,
        tags: [String],
        status: GhostPost.Status,
        date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> OutgoingPost {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanTags = normalizedTags(tags)
        let finalTitle: String
        if trimmedTitle.isEmpty {
            finalTitle = dateTitle(for: date, locale: locale, timeZone: timeZone)
            if !cleanTags.contains(where: { $0.caseInsensitiveCompare(untitledTag) == .orderedSame }) {
                cleanTags.append(untitledTag)
            }
        } else {
            finalTitle = trimmedTitle
            cleanTags.removeAll { $0.caseInsensitiveCompare(untitledTag) == .orderedSame }
        }
        return OutgoingPost(title: finalTitle, html: html(fromMarkdown: markdown), status: status, tags: cleanTags)
    }

    /// e.g. "Thursday, 30 October 2026 · 10:48 PM" (localized).
    public static func dateTitle(for date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var day = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, timeZone: timeZone)
        day.timeZone = timeZone
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        time.timeZone = timeZone
        return "\(date.formatted(day)) · \(date.formatted(time))"
    }

    public static func html(fromMarkdown markdown: String) -> String {
        // Ghost drops <del> on import but keeps <s>.
        MarkdownRenderer.html(from: markdown)
            .replacingOccurrences(of: "<del>", with: "<s>")
            .replacingOccurrences(of: "</del>", with: "</s>")
    }

    /// Trims, drops empties and case-insensitive duplicates, keeps order.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }
}
