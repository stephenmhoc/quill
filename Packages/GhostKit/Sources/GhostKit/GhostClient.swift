import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal Ghost Admin API client (Ghost 6).
public struct GhostClient: Sendable {
    public let baseURL: URL
    let credentials: GhostCredentials
    let session: URLSession

    public init(baseURL: URL, credentials: GhostCredentials, session: URLSession = GhostClient.privateSession) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    /// No disk cache or cookies, and redirects are refused: a signed request (and the writing
    /// in it) only ever goes to the exact site the user chose.
    public static let privateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Normalizes what people paste: adds https, drops `/ghost`, query, trailing slash.
    public static func normalizeSiteURL(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GhostError.invalidURL }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { throw GhostError.invalidURL }
        guard scheme == "https" || ["localhost", "127.0.0.1"].contains(host) else { throw GhostError.invalidURL }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/ghost/api/admin", "/ghost"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        components.path = path
        guard let url = components.url else { throw GhostError.invalidURL }
        return url
    }

    // MARK: Endpoints

    public func site() async throws -> GhostSiteInfo {
        let data = try await send("GET", "site/")
        return try decode(SiteEnvelope.self, from: data).site
    }

    /// Works for staff tokens; integration keys get `unauthorized`.
    public func me() async throws -> GhostUser {
        let data = try await send("GET", "users/me/")
        guard let user = try decode(UsersEnvelope.self, from: data).users.first else {
            throw GhostError.unexpectedResponse("No user returned.")
        }
        return user
    }

    public func createPost(_ post: OutgoingPost) async throws -> GhostPost {
        let data = try await send("POST", "posts/", query: [URLQueryItem(name: "source", value: "html")],
                                  body: PostsEnvelopeOut(posts: [PostBody(post, updatedAt: nil)]))
        return try firstPost(data)
    }

    public func updatePost(id: String, updatedAt: String, _ post: OutgoingPost) async throws -> GhostPost {
        let data = try await send("PUT", "posts/\(id)/", query: [URLQueryItem(name: "source", value: "html")],
                                  body: PostsEnvelopeOut(posts: [PostBody(post, updatedAt: updatedAt)]))
        return try firstPost(data)
    }

    public func post(id: String) async throws -> GhostPost {
        try firstPost(try await send("GET", "posts/\(id)/", query: [
            URLQueryItem(name: "include", value: "tags"),
            URLQueryItem(name: "formats", value: "html"),
        ]))
    }

    public func deletePost(id: String) async throws {
        _ = try await send("DELETE", "posts/\(id)/")
    }

    public func recentPosts(limit: Int = 20, page: Int = 1, tagSlug: String? = nil) async throws -> [GhostPost] {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "order", value: "updated_at desc"),
            URLQueryItem(name: "include", value: "tags"),
            URLQueryItem(name: "fields", value: "id,title,slug,status,url,created_at,updated_at,published_at,excerpt"),
        ]
        if let tagSlug { query.append(URLQueryItem(name: "filter", value: "tag:\(tagSlug)")) }
        let data = try await send("GET", "posts/", query: query)
        return try decode(PostsEnvelopeIn.self, from: data).posts
    }

    /// Totals for every published post. Walks the whole site, so call it sparingly.
    public func publishedStats() async throws -> PostStats {
        let pageSize = 100
        var texts: [String] = []
        var page = 1
        while true {
            let data = try await send("GET", "posts/", query: [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "filter", value: "status:published"),
                URLQueryItem(name: "formats", value: "plaintext"),
                URLQueryItem(name: "fields", value: "id,plaintext"),
            ])
            let posts = try decode(PlaintextEnvelopeIn.self, from: data).posts
            texts += posts.map { $0.plaintext ?? "" }
            if posts.count < pageSize { return await PostStats.counting(texts) }
            page += 1
        }
    }

    /// The post created with this marker, if it landed. Goes by creation order, which later
    /// edits to other posts can't disturb.
    public func post(marker: String, createdSince cutoff: Date) async throws -> GhostPost? {
        let pageSize = 100
        var page = 1
        while true {
            let data = try await send("GET", "posts/", query: [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "order", value: "created_at desc"),
                URLQueryItem(name: "fields", value: "id,title,slug,status,url,created_at,updated_at,published_at,codeinjection_foot"),
            ])
            let posts = try decode(PostsEnvelopeIn.self, from: data).posts
            if let match = posts.first(where: { $0.codeinjectionFoot == Self.footer(for: marker) }) { return match }
            let reachedCutoff = posts.last.flatMap(\.createdAt).map { $0 < cutoff } ?? true
            if reachedCutoff || posts.count < pageSize { return nil }
            page += 1
        }
    }

    /// An HTML comment, so it never shows on the page.
    static func footer(for marker: String) -> String { "<!-- quill:\(marker) -->" }

    public func tags(limit: Int = 100) async throws -> [GhostTag] {
        let data = try await send("GET", "tags/", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "name asc"),
            URLQueryItem(name: "include", value: "count.posts"),
        ])
        return try decode(TagsEnvelope.self, from: data).tags
    }

    /// Uploads an image and returns its public URL.
    public func uploadImage(_ data: Data, filename: String, mimeType: String) async throws -> URL {
        let boundary = "quill-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"purpose\"")
        line("")
        line("image")
        line("--\(boundary)--")
        let response = try await send("POST", "images/upload/", rawBody: body,
                                      contentType: "multipart/form-data; boundary=\(boundary)")
        guard let url = try decode(ImagesEnvelope.self, from: response).images.first?.url else {
            throw GhostError.unexpectedResponse("No image URL returned.")
        }
        return url
    }

    // MARK: Transport

    private func send<Body: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Body) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await send(method, path, query: query, rawBody: try encoder.encode(body), contentType: "application/json")
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      rawBody: Data? = nil, contentType: String? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: "ghost/api/admin/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = rawBody
        request.setValue("Ghost \(credentials.token())", forHTTPHeaderField: "Authorization")
        request.setValue("v6.0", forHTTPHeaderField: "Accept-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.error(from: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GhostError.unexpectedResponse("Not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data)
        }
        return data
    }

    /// Failures before the request could be delivered are safe to resend; others may have landed.
    static func error(from error: URLError) -> GhostError {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .appTransportSecurityRequiresSecureConnection:
            .unreachable(error.localizedDescription)
        default:
            .outcomeUnknown(error.localizedDescription)
        }
    }

    static func error(status: Int, data: Data) -> GhostError {
        let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.errors.first.map {
            [$0.message, $0.context].compactMap { $0 }.joined(separator: " ")
        } ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 300..<400: return .rejected("The site redirected to another address. Use the final address instead.")
        case 401, 403: return .unauthorized(message)
        case 404: return .notFound
        case 409: return .conflict(message)
        case 429: return .server(status: status, message: message)
        case 400..<500: return .rejected(message)
        default: return .server(status: status, message: message)
        }
    }

    private func firstPost(_ data: Data) throws -> GhostPost {
        guard let post = try decode(PostsEnvelopeIn.self, from: data).posts.first else {
            throw GhostError.unexpectedResponse("No post returned.")
        }
        return post
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: .iso8601) { return date }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GhostError.unexpectedResponse(String(describing: error))
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

// MARK: Wire formats

private struct SiteEnvelope: Decodable { let site: GhostSiteInfo }
private struct UsersEnvelope: Decodable { let users: [GhostUser] }
private struct TagsEnvelope: Decodable { let tags: [GhostTag] }
private struct PostsEnvelopeIn: Decodable { let posts: [GhostPost] }
private struct PlaintextEnvelopeIn: Decodable {
    struct Post: Decodable { let plaintext: String? }
    let posts: [Post]
}
private struct ImagesEnvelope: Decodable { struct Image: Decodable { let url: URL }; let images: [Image] }
private struct ErrorEnvelope: Decodable {
    struct Item: Decodable { let message: String?; let context: String? }
    let errors: [Item]
}

private struct PostsEnvelopeOut: Encodable { let posts: [PostBody] }
private struct PostBody: Encodable {
    struct Tag: Encodable { let name: String }
    let title: String
    let html: String
    let status: String
    let tags: [Tag]
    let updatedAt: String?
    let publishedAt: Date?
    let codeinjectionFoot: String?

    init(_ post: OutgoingPost, updatedAt: String?) {
        title = post.title
        html = post.html
        status = post.status.rawValue
        tags = post.tags.map(Tag.init(name:))
        self.updatedAt = updatedAt
        publishedAt = post.publishedAt
        codeinjectionFoot = post.marker.map(GhostClient.footer(for:))
    }

    enum CodingKeys: String, CodingKey {
        case title, html, status, tags
        case codeinjectionFoot = "codeinjection_foot"
        case updatedAt = "updated_at"
        case publishedAt = "published_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(html, forKey: .html)
        try c.encode(status, forKey: .status)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try c.encodeIfPresent(codeinjectionFoot, forKey: .codeinjectionFoot)
    }
}
