import Foundation

/// Totals across a site's published posts.
public struct PostStats: Codable, Sendable, Equatable {
    public let posts: Int
    public let words: Int

    public init(posts: Int, words: Int) {
        self.posts = posts
        self.words = words
    }

    /// Off the main actor: a long-running site can have a lot of words.
    public static func counting(_ texts: [String]) async -> PostStats {
        var words = 0
        for text in texts {
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                words += 1
            }
        }
        return PostStats(posts: texts.count, words: words)
    }
}
