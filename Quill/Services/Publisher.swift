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

    init(lock: AppLock, context: ModelContext) {
        self.lock = lock
        self.context = context
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flushOutbox() }
        }
        monitor.start(queue: .main)
    }

    /// Queue and try right away.
    func publish(_ entry: Entry) async {
        entry.state = .queued
        entry.lastError = nil
        entry.touch()
        try? context.save()
        await send(entry)
    }

    func flushOutbox() async {
        guard lock.isUnlocked else { return }
        let queued = State.queued.rawValue
        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.stateRaw == queued },
                                                sortBy: [SortDescriptor(\.updatedAt)])
        for entry in (try? context.fetch(descriptor)) ?? [] {
            await send(entry)
        }
    }

    /// Conflict resolution: replace whatever is in Ghost with this version.
    func overwrite(_ entry: Entry) async {
        guard let site = site(for: entry), let postID = entry.remotePostID else { return }
        do {
            let latest = try await lock.client(for: site).post(id: postID)
            entry.remoteUpdatedAt = latest.updatedAt
            await publish(entry)
        } catch {
            fail(entry, error)
        }
    }

    private typealias State = Entry.State

    private func send(_ entry: Entry) async {
        guard lock.isUnlocked, !sending.contains(entry.id) else { return }
        guard let site = site(for: entry) else {
            entry.state = .failed
            entry.lastError = "Choose a site for this entry."
            return
        }
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
            if let id = entry.remotePostID, let updatedAt = entry.remoteUpdatedAt {
                post = try await client.updatePost(id: id, updatedAt: updatedAt, outgoing)
            } else {
                post = try await client.createPost(outgoing)
            }
            entry.remotePostID = post.id
            entry.remoteUpdatedAt = post.updatedAt
            entry.remoteURLString = post.url?.absoluteString
            entry.remoteStatusRaw = post.status.rawValue
            entry.sentAt = .now
            entry.lastError = nil
            entry.state = .sent
            site.lastUsedAt = .now
            lastResult = Result(entryID: entry.id, siteName: site.name, url: post.url,
                                status: post.status, wasUpdate: isUpdate)
        } catch let error as GhostError where error.isTransient {
            entry.state = .queued
            entry.lastError = error.localizedDescription
        } catch {
            fail(entry, error)
        }
    }

    private func fail(_ entry: Entry, _ error: Error) {
        entry.state = .failed
        entry.lastError = error.localizedDescription
        try? context.save()
    }

    private func site(for entry: Entry) -> Site? {
        guard let id = entry.siteID else { return nil }
        return try? context.fetch(FetchDescriptor<Site>(predicate: #Predicate { $0.id == id })).first
    }
}

extension Entry {
    var isConflict: Bool {
        state == .failed && (lastError?.contains("changed in Ghost") ?? false)
    }
}
