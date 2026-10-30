import CryptoKit
import Foundation

/// A Ghost Admin API key or Staff Access Token. Both have the form `<id>:<hex secret>`.
public struct GhostCredentials: Sendable, Equatable {
    public let id: String
    let secret: Data

    public init(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let secret = Data(hex: String(parts[1])), secret.count >= 16 else {
            throw GhostError.invalidKey
        }
        self.id = String(parts[0])
        self.secret = secret
    }

    /// The original `id:secret` string, for storage.
    public var apiKey: String { "\(id):\(secret.hexString)" }

    /// A short-lived HS256 JWT for the Admin API (`Authorization: Ghost <token>`).
    public func token(now: Date = .now, lifetime: TimeInterval = 300) -> String {
        let header = ["alg": "HS256", "typ": "JWT", "kid": id]
        let iat = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = ["iat": iat, "exp": iat + Int(lifetime), "aud": "/admin/"]
        let signingInput = Self.base64URL(Self.json(header)) + "." + Self.base64URL(Self.json(payload))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: secret))
        return signingInput + "." + Self.base64URL(Data(mac))
    }

    private static func json(_ object: Any) -> Data {
        // Sorted keys keep tokens deterministic for tests; JWT does not care about order.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
