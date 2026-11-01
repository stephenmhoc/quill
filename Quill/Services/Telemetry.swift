import Foundation
import GhostKit
import Sentry

/// Crash, hang and failure reports, sent to Sentry. Nothing written in Quill may ever reach them:
/// no text, titles, site names or addresses, keys or server messages. So screenshots, the view
/// hierarchy, session replay and the SDK's network, file and Core Data capture all stay off, since
/// each would record some of that. Only this file imports Sentry.
///
/// Nonisolated because the SDK calls its hooks off the main thread, where a closure that inherited
/// MainActor isolation would crash.
nonisolated enum Telemetry {
    private static let dsn = "https://5d999d1c5be67af1130089ab73036de4@o4510771621789696.ingest.us.sentry.io/4512358194806784"

    /// Call first, so a store that can't open is reported. Debug builds, and so the tests, stay
    /// silent unless run with `QUILL_SENTRY=1`.
    static func start() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["QUILL_SENTRY"] != nil else { return }
        #endif
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = releaseName
            options.sendDefaultPii = false

            options.tracesSampleRate = 1.0
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0
                $0.lifecycle = .trace
            }
            options.enableMetricKit = true
            #if os(macOS)
            // AppKit swallows these otherwise, and carries on in a bad state.
            options.enableUncaughtNSExceptionReporting = true
            #endif

            // URLs hold site addresses, and Micropub's hold post addresses.
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            // Sites aren't ours, so nothing of Sentry's goes in the requests to them.
            options.tracePropagationTargets = []
            // Fetch spans quote predicates, and file spans quote paths.
            options.enableCoreDataTracing = false
            options.enableFileIOTracing = false
            options.beforeBreadcrumb = withoutTitle
        }
    }

    /// Navigation titles are site names, and the SDK copies them, and button titles, into breadcrumbs.
    private static func withoutTitle(_ crumb: Breadcrumb) -> Breadcrumb? {
        crumb.setData(value: nil, key: "title")
        return crumb
    }

    private static var environment: String {
        #if DEBUG
        "development"
        #else
        // Local Mac builds of any configuration are the .dev identity.
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "development" : "production"
        #endif
    }

    /// Named by hand because both apps release as com.merimerimeri.Quill, on separate version lines.
    private static var releaseName: String {
        #if os(macOS)
        let app = "quill-mac"
        #else
        let app = "quill-ios"
        #endif
        let info = Bundle.main.infoDictionary
        return "\(app)@\(info?["CFBundleShortVersionString"] ?? "0")+\(info?["CFBundleVersion"] ?? "0")"
    }

    /// Reports a failure that isn't the network or something the person can fix, by its type and
    /// code alone: `localizedDescription`, user info and GhostError's messages can quote the post.
    static func report(_ error: Error, while action: String) {
        guard let safe = safeCopy(of: error) else { return }
        SentrySDK.capture(error: safe) { scope in
            scope.setTag(value: action, key: "action")
        }
    }

    private static func safeCopy(of error: Error) -> NSError? {
        if error is CancellationError { return nil }
        if let error = error as? GhostError {
            switch error {
            case .rejected: return NSError(domain: "GhostError.rejected", code: 0)
            case .unexpectedResponse: return NSError(domain: "GhostError.unexpectedResponse", code: 0)
            // Offline, a key that's been revoked, a post changed elsewhere: Quill handles these.
            default: return nil
            }
        }
        let error = error as NSError
        return error.domain == NSURLErrorDomain ? nil : NSError(domain: error.domain, code: error.code)
    }

    /// Times one operation, tagged with the kind of site, such as a publish.
    struct Timing {
        private let transaction: any Span

        init(_ name: String, siteKind: String) {
            transaction = SentrySDK.startTransaction(name: name, operation: "quill.\(name)")
            transaction.setTag(value: siteKind, key: "site.kind")
        }

        func finish(succeeded: Bool) {
            transaction.finish(status: succeeded ? .ok : .internalError)
        }
    }
}
