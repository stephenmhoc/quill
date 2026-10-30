import Foundation
import GhostKit
import SwiftData

/// A piece of writing. Lives on this device only; becomes a Ghost post when sent.
@Model
final class Entry {
    enum State: String, Codable {
        /// Being written (or reopened to edit after sending).
        case editing
        /// Waiting in the outbox to be sent.
        case queued
        case sending
        case sent
        /// Needs the user (bad key, conflict, validation). Transient failures stay `queued`.
        case failed
    }

    @Attribute(.unique) var id: UUID
    var siteID: UUID?
    var title: String
    var body: String
    var tags: [String]
    /// What to do on send: publish or create a Ghost draft.
    var publishRaw: String
    var stateRaw: String
    /// When writing started; an untitled entry is titled with this date.
    var createdAt: Date
    var updatedAt: Date

    var remotePostID: String?
    var remoteUpdatedAt: String?
    var remoteURLString: String?
    var remoteStatusRaw: String?
    var sentAt: Date?
    var lastError: String?
    /// "conflict" when Ghost changed underneath us; nil otherwise.
    var failureReason: String?
    /// Set before a create; cleared once we know the outcome. If it's still set on retry, the
    /// post may already exist, so look for it instead of creating a duplicate.
    var createAttemptedAt: Date?
    /// Images already live on this site, so the entry can't move to another one.
    var uploadedToSiteID: UUID?
    /// The published version, kept while editing it so going back can restore it.
    var publishedTitle: String?
    var publishedBody: String?
    var publishedTags: [String]?

    init(siteID: UUID?) {
        id = UUID()
        self.siteID = siteID
        title = ""
        body = ""
        tags = []
        publishRaw = GhostPost.Status.published.rawValue
        stateRaw = State.editing.rawValue
        createdAt = .now
        updatedAt = .now
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .editing }
        set { stateRaw = newValue.rawValue }
    }

    var publishStatus: GhostPost.Status {
        get { GhostPost.Status(rawValue: publishRaw) ?? .published }
        set { publishRaw = newValue.rawValue }
    }

    var remoteURL: URL? { remoteURLString.flatMap(URL.init(string:)) }
    var remoteStatus: GhostPost.Status? { remoteStatusRaw.flatMap(GhostPost.Status.init(rawValue:)) }

    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The title shown in lists: the real title, else the first line of the body.
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-_ ").union(.whitespaces))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }

    func outgoing() -> OutgoingPost {
        EntryBuilder.post(title: title, markdown: body, tags: tags, status: publishStatus, date: createdAt)
    }

    func touch() { updatedAt = .now }

    func beginEdit() {
        publishedTitle = title
        publishedBody = body
        publishedTags = tags
        state = .editing
    }

    /// Leaving a published entry mid-edit cancels the edit.
    func cancelEdit() {
        guard state == .editing, remotePostID != nil else { return }
        title = publishedTitle ?? title
        body = publishedBody ?? body
        tags = publishedTags ?? tags
        clearPublishedCopy()
        state = .sent
        try? modelContext?.save()
    }

    func clearPublishedCopy() {
        publishedTitle = nil
        publishedBody = nil
        publishedTags = nil
    }
}
