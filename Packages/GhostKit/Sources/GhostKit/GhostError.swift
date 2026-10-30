import Foundation

public enum GhostError: Error, Equatable, Sendable {
    /// The key or token isn't in `id:secret` form.
    case invalidKey
    /// The site URL couldn't be parsed.
    case invalidURL
    /// The site couldn't be reached (offline, DNS, Tailscale not connected, TLS failure).
    case unreachable(String)
    /// The connection dropped after the request may have reached the server.
    case outcomeUnknown(String)
    /// 401/403: the token is wrong, revoked, or lacks permission.
    case unauthorized(String)
    case notFound
    /// 409: the post changed on the server since we last saw it.
    case conflict(String)
    /// 422 and other 4xx validation problems.
    case rejected(String)
    case server(status: Int, message: String)
    /// The response wasn't what the Admin API returns (wrong URL, proxy page, etc.).
    case unexpectedResponse(String)

    /// Worth retrying later without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .outcomeUnknown: true
        case .server(let status, _): status >= 500 || status == 429
        default: false
        }
    }
}

extension GhostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            "That doesn't look like a Ghost key. It should look like 6ae4…:3f2b… (an ID, a colon, then a long hex secret)."
        case .invalidURL:
            "That site address isn't valid."
        case .unreachable(let detail):
            "Couldn't reach the site. If it's on your tailnet, check that Tailscale is connected. (\(detail))"
        case .unauthorized(let message):
            "The site rejected the key: \(message)"
        case .outcomeUnknown(let detail):
            "The connection dropped before the site answered. (\(detail))"
        case .notFound:
            "Not found on the site. Check the address."
        case .conflict(let message):
            "The post was changed on the site since it was last synced. \(message)"
        case .rejected(let message):
            "The site refused the request: \(message)"
        case .server(let status, let message):
            "The site returned an error (\(status)): \(message)"
        case .unexpectedResponse(let detail):
            "The site didn't respond like a Ghost Admin API. \(detail)"
        }
    }
}
