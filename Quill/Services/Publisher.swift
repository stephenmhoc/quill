import Foundation
import GhostKit
import Network
import Observation
import SwiftData

/// Sends entries to Ghost and runs the outbox. Transient failures (offline, Tailscale off,
/// 5xx) leave the entry queued for a later retry; anything that needs the user marks it failed.
@Observable
final class Publisher {
    struct Result: Identifiable, Equatable {
        let id = UUID()
        let entryID: UUID
        let siteName: String
        let url: URL?
        let status: GhostPost.Status
        let wasUpdate: Bool
    }

    private(set) var sending: Set<UUID> = []
    var lastResult: Result?

    private let lock: AppLock
    private let context: ModelContext
    private let monitor = NWPathMonitor()
    private var isFlushing = false

    init(lock: AppLock, context: ModelContext) {
        self.lock = lock
        self.context = context
        recoverInterrupted()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flushOutbox() }
        }
        monitor.start(queue: .main)
    }

    /// Queue and try right away. Saved first, so a save failure never looks like a send.
    func publish(_ entry: Entry) async {
        guard [.editing, .queued, .failed].contains(entry.state) else { return }
        entry.state = .queued
        entry.lastError = nil
        entry.failureReason = nil
        entry.touch()
        do {
            try context.save()
        } catch {
            fail(entry, error)
            return
        }
        await send(entry)
    }

    func flushOutbox() async {
        guard lock.canWork, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let queued = Entry.State.queued.rawValue
        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.stateRaw == queued },
                                                sortBy: [SortDescriptor(\.updatedAt)])
        for entry in (try? context.fetch(descriptor)) ?? [] {
            await send(entry)
        }
    }

    /// Conflict resolution: replace whatever is in Ghost with this version.
    func overwrite(_ entry: Entry) async {
        guard entry.state == .failed, !sending.contains(entry.id),
              let site = site(for: entry), let postID = entry.remotePostID else { return }
        sending.insert(entry.id)
        do {
            let latest = try await lock.client(for: site).post(id: postID)
            entry.remoteUpdatedAt = latest.updatedAt
            sending.remove(entry.id)
            await publish(entry)
        } catch {
            sending.remove(entry.id)
            fail(entry, error)
        }
    }

    /// Brings a post from Ghost into Quill so it can be edited.
    /// Nil if the post has content Markdown can't hold: editing it here would lose that content.
    func importPost(id: String, site: Site) async throws -> Entry? {
        let post = try await lock.client(for: site).post(id: id)
        guard post.status == .published || post.status == .draft,
              let body = HTMLToMarkdown.convert(post.html ?? "") else { return nil }
        let tags = (post.tags ?? []).map(\.name)
        let entry = Entry(siteID: site.id)
        entry.title = tags.contains(EntryBuilder.untitledTag) ? "" : post.title
        entry.body = body
        entry.tags = tags.filter { $0 != EntryBuilder.untitledTag }
        entry.publishStatus = post.status
        entry.createdAt = post.publishedAt ?? post.createdAt ?? .now
        entry.state = .sent
        entry.sentAt = entry.createdAt
        entry.remotePostID = post.id
        entry.remoteUpdatedAt = post.updatedAt
        entry.remoteURLString = post.url?.absoluteString
        entry.remoteStatusRaw = post.status.rawValue
        context.insert(entry)
        try context.save()
        return entry
    }

    /// Permanently deletes a post from Ghost, and Quill's copy of it.
    func deletePost(id: String, site: Site) async throws {
        do {
            try await lock.client(for: site).deletePost(id: id)
        } catch GhostError.notFound {
            // Already gone from Ghost; still clear the local copy.
        }
        let siteID = site.id
        let local = FetchDescriptor<Entry>(predicate: #Predicate { $0.remotePostID == id && $0.siteID == siteID })
        for entry in try context.fetch(local) { context.delete(entry) }
        try context.save()
    }

    /// A crash or kill mid-send leaves `.sending` behind; put those back in the outbox.
    private func recoverInterrupted() {
        let stuck = Entry.State.sending.rawValue
        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.stateRaw == stuck })
        for entry in (try? context.fetch(descriptor)) ?? [] { entry.state = .queued }
        try? context.save()
    }

    private func send(_ entry: Entry) async {
        // Re-checked here because a flush can hold a list fetched before an earlier await.
        guard lock.canWork, entry.modelContext != nil, entry.state == .queued, !sending.contains(entry.id) else { return }
        guard let site = site(for: entry) else {
            entry.state = .failed
            entry.lastError = "Choose a site for this entry."
            try? context.save()
            return
        }
        // An earlier attempt whose outcome is unknown must survive later network failures.
        let unresolvedAttempt = entry.createAttemptedAt != nil
        sending.insert(entry.id)
        entry.state = .sending
        defer {
            sending.remove(entry.id)
            try? context.save()
        }
        do {
            let client = try lock.client(for: site)
            let outgoing = entry.outgoing()
            let isUpdate = entry.remotePostID != nil
            let post: GhostPost
            if let id = entry.remotePostID {
                let updatedAt = try await resolvedUpdatedAt(entry, id: id, client: client)
                post = try await client.updatePost(id: id, updatedAt: updatedAt, outgoing)
            } else if let attempted = entry.createAttemptedAt,
                      let existing = try await findCreated(outgoing, since: attempted, client: client) {
                post = existing
            } else {
                if entry.createAttemptedAt == nil { entry.createAttemptedAt = .now }
                try context.save()
                // An entry that waited in the outbox is dated when it was written.
                var dated = outgoing
                if dated.status == .published { dated.publishedAt = entry.createdAt }
                post = try await client.createPost(dated)
            }
            entry.remotePostID = post.id
            entry.remoteUpdatedAt = post.updatedAt
            entry.remoteURLString = post.url?.absoluteString
            entry.remoteStatusRaw = post.status.rawValue
            entry.sentAt = .now
            entry.lastError = nil
            entry.createAttemptedAt = nil
            entry.clearPublishedCopy()
            entry.state = .sent
            site.lastUsedAt = .now
            lastResult = Result(entryID: entry.id, siteName: site.name, url: post.url,
                                status: post.status, wasUpdate: isUpdate)
        } catch let error as GhostError where error.isTransient {
            // `.unreachable` never left the phone, so a fresh attempt can't have landed.
            if case .unreachable = error, !unresolvedAttempt { entry.createAttemptedAt = nil }
            entry.state = .queued
            entry.lastError = error.localizedDescription
        } catch {
            fail(entry, error)
        }
    }

    private func resolvedUpdatedAt(_ entry: Entry, id: String, client: GhostClient) async throws -> String {
        if let known = entry.remoteUpdatedAt { return known }
        return try await client.post(id: id).updatedAt
    }

    /// After an attempt with an unknown outcome: did that post land? Title plus creation time
    /// identifies it; more than one match needs a human.
    private func findCreated(_ outgoing: OutgoingPost, since: Date, client: GhostClient) async throws -> GhostPost? {
        let cutoff = since.addingTimeInterval(-120) // allow for clock differences
        let matches = try await client.recentPosts(limit: 30).filter {
            $0.title == outgoing.title && ($0.createdAt ?? .distantPast) >= cutoff
        }
        if matches.count > 1 {
            throw GhostError.rejected("Found \(matches.count) posts with this title. Check Ghost for duplicates.")
        }
        return matches.first
    }

    private func fail(_ entry: Entry, _ error: Error) {
        entry.state = .failed
        entry.lastError = error.localizedDescription
        if case GhostError.conflict = error { entry.failureReason = "conflict" }
        try? context.save()
    }

    private func site(for entry: Entry) -> Site? {
        guard let id = entry.siteID else { return nil }
        return try? context.fetch(FetchDescriptor<Site>(predicate: #Predicate { $0.id == id })).first
    }
}

extension Entry {
    var isConflict: Bool { state == .failed && failureReason == "conflict" }
}
