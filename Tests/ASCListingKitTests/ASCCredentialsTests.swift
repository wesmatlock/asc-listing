@testable import ASCListingKit
import Foundation
import Testing

struct ASCCredentialsTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    private func reader(_ files: [String: String]) -> @Sendable (URL) throws -> Data {
        { url in
            guard let content = files[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
            return Data(content.utf8)
        }
    }

    @Test func `environment wins over the config file`() throws {
        let files = [
            "/keys/env.p8": "ENV-PEM",
            "/Users/tester/.appstoreconnect/config.json": #"{"keyId":"CFG","issuerId":"CFGI","p8Path":"/keys/cfg.p8"}"#,
            "/keys/cfg.p8": "CFG-PEM"
        ]
        let credentials = try ASCCredentials.resolve(
            environment: ["ASC_KEY_ID": "ENV", "ASC_ISSUER_ID": "ENVI", "ASC_P8_PATH": "/keys/env.p8"],
            homeDirectory: home,
            fileReader: reader(files)
        )
        #expect(credentials == ASCCredentials(keyId: "ENV", issuerId: "ENVI", privateKeyPEM: "ENV-PEM"))
    }

    @Test func `config file expands tilde in the path`() throws {
        let files = [
            "/Users/tester/.appstoreconnect/config.json": #"{"keyId":"CFG","issuerId":"CFGI","p8Path":"~/keys/AuthKey_CFG.p8"}"#,
            "/Users/tester/keys/AuthKey_CFG.p8": "CFG-PEM"
        ]
        let credentials = try ASCCredentials.resolve(environment: [:], homeDirectory: home, fileReader: reader(files))
        #expect(credentials == ASCCredentials(keyId: "CFG", issuerId: "CFGI", privateKeyPEM: "CFG-PEM"))
    }

    @Test func `partial environment falls back to the config file`() throws {
        let files = [
            "/Users/tester/.appstoreconnect/config.json": #"{"keyId":"CFG","issuerId":"CFGI","p8Path":"/keys/cfg.p8"}"#,
            "/keys/cfg.p8": "CFG-PEM"
        ]
        let credentials = try ASCCredentials.resolve(
            environment: ["ASC_KEY_ID": "ENV"],
            homeDirectory: home,
            fileReader: reader(files)
        )
        #expect(credentials.keyId == "CFG")
    }

    @Test func `missing everything names both sources`() {
        do {
            _ = try ASCCredentials.resolve(environment: [:], homeDirectory: home, fileReader: reader([:]))
            Issue.record("expected a throw")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("ASC_KEY_ID"))
            #expect(message.contains("~/.appstoreconnect/config.json"))
        }
    }

    @Test func `unreadable key is reported`() {
        let files = ["/Users/tester/.appstoreconnect/config.json": #"{"keyId":"K","issuerId":"I","p8Path":"/missing.p8"}"#]
        #expect(throws: ASCError.self) {
            try ASCCredentials.resolve(environment: [:], homeDirectory: home, fileReader: reader(files))
        }
    }
}
