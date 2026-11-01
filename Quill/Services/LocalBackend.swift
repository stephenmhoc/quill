import Foundation
import GhostKit
import SwiftData

/// A site that lives only on this device. Its posts are entries that have been saved to it,
/// using the entry's own ID as the post ID.
struct LocalBackend: SiteBackend {
    let site: Site
    let context: ModelContext

    /// Markdown refers to images by this scheme, because the app's folder moves between installs.
    static let imageScheme = "quill-local"

    func posts(limit: Int, page: Int, tag: SiteTag?) async throws -> [SitePost] {
        try saved().filter { tag == nil || $0.tags.contains(tag?.name ?? "") }.dropFirst(limit * (page - 1)).prefix(limit).map { entry in
            SitePost(id: entry.remotePostID ?? entry.id.uuidString, title: entry.displayTitle,
                     isUntitled: entry.title.isEmpty, date: entry.createdAt, badge: nil, url: nil, tags: entry.tags)
        }
    }

    func stats() async throws -> PostStats {
        await PostStats.counting(try saved().map(\.body))
    }

    func entry(forPost id: String) async throws -> Entry? {
        try saved().first { $0.remotePostID == id }
    }

    /// The copy here is the only one.
    func refresh(_ entry: Entry) async throws {}

    func deletePost(id: String) async throws {
        for entry in try saved() where entry.remotePostID == id { delete(entry) }
        try context.save()
    }

    func send(_ entry: Entry) async throws -> SentPost {
        SentPost(id: entry.remotePostID ?? entry.id.uuidString, updatedAt: nil, url: nil, status: .published)
    }

    /// Only this device writes to a local site, so there's never another version.
    func adoptLatestVersion(of entry: Entry) async throws {}

    func takeLatestVersion(of entry: Entry) async throws {}

    func tags() async throws -> [String] {
        Array(Set(try saved().flatMap(\.tags))).sorted()
    }

    func filterTags() async throws -> [SiteTag] {
        try await tags().filter { !$0.hasPrefix("#") }.map { SiteTag(id: $0, name: $0) }
    }

    func uploadImage(_ jpeg: Data, filename: String) async throws -> URL {
        let folder = try Self.imageFolder()
        try jpeg.write(to: folder.appending(path: filename), options: .completeFileProtection)
        guard let url = URL(string: "\(Self.imageScheme)://images/\(filename)") else { throw GhostError.invalidURL }
        return url
    }

    func removeSiteData() throws {
        let siteID = site.id
        let entries = try context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.siteID == siteID }))
        for entry in entries { delete(entry) }
    }

    private func saved() throws -> [Entry] {
        let siteID = site.id
        return try context.fetch(FetchDescriptor<Entry>(
            predicate: #Predicate { $0.siteID == siteID && $0.remotePostID != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    private func delete(_ entry: Entry) {
        for name in Self.imageNames(in: entry.body) {
            if let folder = try? Self.imageFolder() { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
        }
        context.delete(entry)
    }

    private static func imageNames(in markdown: String) -> [String] {
        markdown.matches(of: /quill-local:\/\/images\/([^)\s]+)/).map { String($0.1) }
    }

    /// The bytes behind a `quill-local` image, for showing it outside the editor.
    static func image(named name: String) throws -> Data {
        try Data(contentsOf: imageFolder().appending(path: name))
    }

    /// Kept out of backups, like the rest of the writing.
    private static func imageFolder() throws -> URL {
        var folder = URL.applicationSupportDirectory.appending(path: "LocalImages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }
}
