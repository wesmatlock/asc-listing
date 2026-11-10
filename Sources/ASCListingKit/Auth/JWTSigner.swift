import CryptoKit
import Foundation

public struct TokenClock: Sendable {
    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    public static let system = TokenClock { Date() }
}

public actor JWTSigner {
    public static let lifetime: TimeInterval = 900
    public static let refreshAfter: TimeInterval = 14 * 60

    private let keyId: String
    private let issuerId: String
    private let key: P256.Signing.PrivateKey
    private let clock: TokenClock
    private var cached: (token: String, issuedAt: Date)?

    public init(credentials: ASCCredentials, clock: TokenClock = .system) throws {
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        } catch {
            throw ASCError.invalidCredentials("the private key is not a valid PEM-encoded P-256 key")
        }
        keyId = credentials.keyId
        issuerId = credentials.issuerId
        self.clock = clock
    }

    public func token() throws -> String {
        let now = clock.now()
        if let cached, now.timeIntervalSince(cached.issuedAt) < Self.refreshAfter, now >= cached.issuedAt {
            return cached.token
        }
        let token = try sign(issuedAt: now)
        cached = (token, now)
        return token
    }

    private struct Header: Encodable {
        let alg = "ES256"
        let kid: String
        let typ = "JWT"
    }

    private struct Claims: Encodable {
        let iss: String
        let iat: Int
        let exp: Int
        let aud = "appstoreconnect-v1"
    }

    private func sign(issuedAt: Date) throws -> String {
        let iat = Int(issuedAt.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(Header(kid: keyId))
        let claims = try encoder.encode(Claims(iss: issuerId, iat: iat, exp: iat + Int(Self.lifetime)))
        let signingInput = Self.base64URL(header) + "." + Self.base64URL(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
