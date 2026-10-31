import CryptoKit
import Foundation

/// A post as a Micropub server holds it. Micropub identifies posts by URL.
public struct MicropubPost: Sendable, Equatable {
    public let url: String
    public let title: String
    public let content: String
    public let categories: [String]
    public let status: GhostPost.Status
    public let published: Date?

    /// Micropub has no `updated_at`, so this fingerprint stands in for it: a post that no longer
    /// matches changed somewhere else.
    public var version: String {
        let digest = SHA256.hash(data: Data(([title, content] + categories).joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Client for Micro.blog's Micropub API. Bearer token, Markdown in and out.
public struct MicropubClient: Sendable {
    public struct Destination: Sendable, Equatable, Identifiable {
        public let uid: String
        public let name: String
        public let title: String?
        public var id: String { uid }
    }

    public static let endpoint = URL(string: "https://micro.blog/micropub")!
    static let mediaEndpoint = URL(string: "https://micro.blog/micropub/media")!

    let token: String
    /// The blog to act on. Nil only while listing an account's blogs.
    let destination: String?
    let session: URLSession

    public init(token: String, destination: String? = nil, session: URLSession = GhostClient.privateSession) {
        self.token = token
        self.destination = destination
        self.session = session
    }

    public func destinations() async throws -> [Destination] {
        let data = try await get(Self.endpoint, [URLQueryItem(name: "q", value: "config")])
        return try decode(ConfigIn.self, from: data).destination.map {
            Destination(uid: $0.uid, name: $0.name, title: $0.title)
        }
    }

    public func posts(limit: Int, offset: Int) async throws -> [MicropubPost] {
        let data = try await get(Self.endpoint, scoped([
            URLQueryItem(name: "q", value: "source"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]))
        return try decode(ItemsIn.self, from: data).items.map(\.post)
    }

    /// Totals for every published post. Walks the whole blog, so call it sparingly.
    public func publishedStats() async throws -> PostStats {
        let pageSize = 100
        var texts: [String] = []
        var offset = 0
        while true {
            let page = try await posts(limit: pageSize, offset: offset)
            if page.isEmpty { return await PostStats.counting(texts) }
            texts += page.filter { $0.status == .published }.map(\.content)
            offset += page.count
        }
    }

    public func post(url: String) async throws -> MicropubPost {
        let data = try await get(Self.endpoint, scoped([
            URLQueryItem(name: "q", value: "source"),
            URLQueryItem(name: "url", value: url),
        ]))
        return try decode(ItemIn.self, from: data).post
    }

    public func categories() async throws -> [String] {
        let data = try await get(Self.endpoint, scoped([URLQueryItem(name: "q", value: "category")]))
        return try decode(CategoriesIn.self, from: data).categories
    }

    /// Returns the new post's URL.
    public func create(title: String, content: String, categories: [String], status: GhostPost.Status,
                       published: Date?) async throws -> String {
        var properties: [String: [String]] = [
            "content": [content],
            "category": categories,
            "post-status": [status == .draft ? "draft" : "published"],
        ]
        if !title.isEmpty { properties["name"] = [title] }
        if let published { properties["published"] = [published.ISO8601Format()] }
        if let destination { properties["mp-destination"] = [destination] }
        return try await postURL(CreateOut(type: ["h-entry"], mpDestination: destination, properties: properties))
    }

    /// Returns the post's URL, which an edit can change.
    public func update(url: String, title: String, content: String, categories: [String],
                       status: GhostPost.Status) async throws -> String {
        let replace = [
            "name": [title],
            "content": [content],
            "category": categories,
            "post-status": [status == .draft ? "draft" : "published"],
        ]
        let response = try await postURL(UpdateOut(url: url, mpDestination: destination, replace: replace), fallback: url)
        return response
    }

    public func delete(url: String) async throws {
        _ = try await send(Self.endpoint, method: "POST", body: try JSONEncoder().encode(
            ActionOut(action: "delete", url: url, mpDestination: destination)), contentType: "application/json")
    }

    /// Uploads an image and returns its URL. It can take a few seconds to appear there.
    public func uploadImage(_ data: Data, filename: String, mimeType: String) async throws -> URL {
        let boundary = "quill-\(UUID().uuidString)"
        var body = Data()
        if let destination {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"mp-destination\"\r\n\r\n\(destination)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (_, response) = try await exchange(Self.mediaEndpoint, method: "POST", body: body,
                                               contentType: "multipart/form-data; boundary=\(boundary)")
        guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw GhostError.unexpectedResponse("No image URL returned.")
        }
        return url
    }

    public func deleteImage(url: URL) async throws {
        var form = URLComponents()
        form.queryItems = scoped([URLQueryItem(name: "action", value: "delete"),
                                  URLQueryItem(name: "url", value: url.absoluteString)])
        _ = try await send(Self.mediaEndpoint, method: "POST", body: Data((form.percentEncodedQuery ?? "").utf8),
                           contentType: "application/x-www-form-urlencoded")
    }

    // MARK: Transport

    private func scoped(_ query: [URLQueryItem]) -> [URLQueryItem] {
        query + (destination.map { [URLQueryItem(name: "mp-destination", value: $0)] } ?? [])
    }

    private func postURL(_ body: some Encodable, fallback: String? = nil) async throws -> String {
        let (_, response) = try await exchange(Self.endpoint, method: "POST", body: try JSONEncoder().encode(body),
                                               contentType: "application/json")
        guard let url = response.value(forHTTPHeaderField: "Location") ?? fallback else {
            throw GhostError.unexpectedResponse("No post URL returned.")
        }
        return url
    }

    private func get(_ url: URL, _ query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return try await send(components.url!, method: "GET")
    }

    private func send(_ url: URL, method: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        try await exchange(url, method: method, body: body, contentType: contentType).0
    }

    private func exchange(_ url: URL, method: String, body: Data?, contentType: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GhostClient.error(from: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GhostError.unexpectedResponse("Not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
        return (data, http)
    }

    static func error(status: Int, data: Data) -> GhostError {
        let message = (try? JSONDecoder().decode(ErrorIn.self, from: data))?.errorDescription
            ?? String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 400 where message.localizedCaseInsensitiveContains("not found"): return .notFound
        case 300..<400: return .rejected("Micro.blog redirected the request.")
        case 401, 403: return .unauthorized(message)
        case 404: return .notFound
        case 429: return .server(status: status, message: message)
        case 400..<500: return .rejected(message)
        default: return .server(status: status, message: message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GhostError.unexpectedResponse(String(describing: error))
        }
    }
}

// MARK: Wire formats

private struct ConfigIn: Decodable {
    struct Blog: Decodable {
        let uid: String
        let name: String
        let title: String?
        enum CodingKeys: String, CodingKey {
            case uid, name
            case title = "microblog-title"
        }
    }
    let destination: [Blog]
}

private struct ItemsIn: Decodable { let items: [ItemIn] }

private struct ItemIn: Decodable {
    struct Properties: Decodable {
        let name: [String]?
        let content: [String]?
        let category: [String]?
        let published: [String]?
        let url: [String]
        let postStatus: [String]?
        enum CodingKeys: String, CodingKey {
            case name, content, category, published, url
            case postStatus = "post-status"
        }
    }
    let properties: Properties

    var post: MicropubPost {
        MicropubPost(url: properties.url.first ?? "", title: properties.name?.first ?? "",
                     content: properties.content?.first ?? "", categories: properties.category ?? [],
                     status: properties.postStatus?.first == "draft" ? .draft : .published,
                     published: properties.published?.first.flatMap { try? Date($0, strategy: .iso8601) })
    }
}

private struct CategoriesIn: Decodable { let categories: [String] }

private struct ErrorIn: Decodable {
    let errorDescription: String?
    enum CodingKeys: String, CodingKey { case errorDescription = "error_description" }
}

private struct CreateOut: Encodable {
    let type: [String]
    let mpDestination: String?
    let properties: [String: [String]]
    enum CodingKeys: String, CodingKey {
        case type, properties
        case mpDestination = "mp-destination"
    }
}

private struct UpdateOut: Encodable {
    var action = "update"
    let url: String
    let mpDestination: String?
    let replace: [String: [String]]
    enum CodingKeys: String, CodingKey {
        case action, url, replace
        case mpDestination = "mp-destination"
    }
}

private struct ActionOut: Encodable {
    let action: String
    let url: String
    let mpDestination: String?
    enum CodingKeys: String, CodingKey {
        case action, url
        case mpDestination = "mp-destination"
    }
}
