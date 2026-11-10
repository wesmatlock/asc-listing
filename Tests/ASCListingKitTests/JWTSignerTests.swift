@testable import ASCListingKit
import CryptoKit
import Foundation
import Testing

struct JWTSignerTests {
    private func decodeSegment(_ segment: Substring) throws -> Data {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return try #require(Data(base64Encoded: base64))
    }

    @Test func `signs A verifiable token`() async throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signer = try JWTSigner(credentials: makeCredentials(key: key), clock: TokenClock { now })

        let token = try await signer.token()
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(!token.contains("="))

        let header = try #require(try JSONSerialization.jsonObject(with: decodeSegment(parts[0])) as? [String: Any])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY1234567")
        #expect(header["typ"] as? String == "JWT")
        #expect(header.count == 3)

        let claims = try #require(try JSONSerialization.jsonObject(with: decodeSegment(parts[1])) as? [String: Any])
        #expect(claims["iss"] as? String == "issuer-uuid")
        #expect(claims["iat"] as? Int == 1_800_000_000)
        #expect(claims["exp"] as? Int == 1_800_000_900)
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims.count == 4)

        let signatureBytes = try decodeSegment(parts[2])
        #expect(signatureBytes.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        #expect(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test func `caches for fourteen minutes`() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let signer = try JWTSigner(credentials: makeCredentials(), clock: clock.clock)

        let first = try await signer.token()
        clock.advance(by: 13 * 60 + 59)
        #expect(try await signer.token() == first)

        clock.advance(by: 2)
        let refreshed = try await signer.token()
        #expect(refreshed != first)
        #expect(try await signer.token() == refreshed)
    }

    @Test func `rejects an invalid key`() {
        let credentials = ASCCredentials(keyId: "K", issuerId: "I", privateKeyPEM: "not a key")
        #expect(throws: ASCError.self) { try JWTSigner(credentials: credentials) }
    }
}
