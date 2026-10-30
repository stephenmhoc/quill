import Foundation
import GhostKit
import Network
import Observation
import SwiftData

/// Sends entries to Ghost and runs the outbox. Transient failures (offline, Tailscale off,
/// 5xx) leave the entry queued for a later retry; anything that needs the user marks it failed.
@Observable
final class Publisher {
    private(set) var sending: Set<UUID> = []
    /// Goes up with every post a site accepts, so lists know to reload.
    private(set) var sentCount = 0

    let lock: AppLock
    let context: ModelContext
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

    /// The outbox's Retry All. Conflicts stay put: they need a decision, not another try.
    func retryAll() async {
        let failed = Entry.State.failed.rawValue
        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.stateRaw == failed })
        for entry in (try? context.fetch(descriptor)) ?? [] where !entry.isConflict {
            entry.state = .queued
        }
        await flushOutbox()
    }

    /// Conflict resolution: replace whatever is on the site with this version.
    func overwrite(_ entry: Entry) async {
        guard entry.state == .failed, !sending.contains(entry.id), let site = site(for: entry) else { return }
        sending.insert(entry.id)
        do {
            try await backend(for: site).adoptLatestVersion(of: entry)
            sending.remove(entry.id)
            if entry.modelContext != nil, !entry.isDeleted { await publish(entry) }
        } catch {
            sending.remove(entry.id)
            fail(entry, error)
        }
    }

    /// Conflict resolution: drop this edit and take what's on the site.
    func takeSiteVersion(_ entry: Entry) async {
        guard entry.isConflict, !sending.contains(entry.id), let site = site(for: entry) else { return }
        sending.insert(entry.id)
        defer { sending.remove(entry.id) }
        do {
            try await backend(for: site).takeLatestVersion(of: entry)
        } catch where entry.modelContext != nil && !entry.isDeleted {
            entry.lastError = error.localizedDescription
        } catch {}
    }

    /// Brings a post into Quill so it can be edited.
    /// Nil if the post has content Markdown can't hold: editing it here would lose that content.
    func importPost(id: String, site: Site) async throws -> Entry? {
        try await backend(for: site).entry(forPost: id)
    }

    /// Picks up changes made on the site. A failure is fine: the copy here still opens.
    func refresh(_ entry: Entry, site: Site) async {
        guard entry.state == .sent else { return }
        try? await backend(for: site).refresh(entry)
    }

    func deletePost(id: String, site: Site) async throws {
        try await backend(for: site).deletePost(id: id)
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
            let post = try await backend(for: site).send(entry)
            // Deleted while the request was out, along with its site or on its own.
            guard entry.modelContext != nil, !entry.isDeleted else { return }
            entry.remotePostID = post.id
            entry.remoteUpdatedAt = post.updatedAt
            entry.remoteURLString = post.url?.absoluteString
            entry.remoteStatusRaw = post.status.rawValue
            entry.sentAt = .now
            entry.lastError = nil
            entry.createAttemptedAt = nil
            entry.clearPublishedCopy()
            entry.state = .sent
            if site.modelContext != nil, !site.isDeleted { site.lastUsedAt = .now }
            sentCount += 1
        } catch where entry.modelContext == nil || entry.isDeleted {
            return
        } catch let error as GhostError where error.isTransient {
            // `.unreachable` never left the phone, so a fresh attempt can't have landed.
            if case .unreachable = error, !unresolvedAttempt { entry.createAttemptedAt = nil }
            entry.state = .queued
            entry.lastError = error.localizedDescription
        } catch {
            fail(entry, error)
        }
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
