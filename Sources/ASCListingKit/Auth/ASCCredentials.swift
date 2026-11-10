import Foundation

public struct ASCCredentials: Sendable, Equatable {
    public let keyId: String
    public let issuerId: String
    public let privateKeyPEM: String

    public init(keyId: String, issuerId: String, privateKeyPEM: String) {
        self.keyId = keyId
        self.issuerId = issuerId
        self.privateKeyPEM = privateKeyPEM
    }

    public static let configRelativePath = ".appstoreconnect/config.json"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileReader: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> ASCCredentials {
        let fromEnvironment = (
            nonEmpty(environment["ASC_KEY_ID"]),
            nonEmpty(environment["ASC_ISSUER_ID"]),
            nonEmpty(environment["ASC_P8_PATH"])
        )
        if case let (keyId?, issuerId?, p8Path?) = fromEnvironment {
            return try credentials(
                keyId: keyId, issuerId: issuerId, p8Path: p8Path, home: homeDirectory, fileReader: fileReader
            )
        }

        let configURL = homeDirectory.appending(path: configRelativePath)
        let configData: Data
        do {
            configData = try fileReader(configURL)
        } catch {
            throw ASCError.missingCredentials
        }

        let config: ConfigFile
        do {
            config = try JSONDecoder().decode(ConfigFile.self, from: configData)
        } catch {
            throw ASCError.invalidCredentials("~/\(configRelativePath) must contain keyId, issuerId and p8Path")
        }
        return try credentials(
            keyId: config.keyId, issuerId: config.issuerId, p8Path: config.p8Path, home: homeDirectory, fileReader: fileReader
        )
    }

    private struct ConfigFile: Decodable {
        let keyId: String
        let issuerId: String
        let p8Path: String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func credentials(
        keyId: String,
        issuerId: String,
        p8Path: String,
        home: URL,
        fileReader: @Sendable (URL) throws -> Data
    ) throws -> ASCCredentials {
        let url = expandTilde(p8Path, home: home)
        let data: Data
        do {
            data = try fileReader(url)
        } catch {
            throw ASCError.invalidCredentials("cannot read the private key at \(url.path)")
        }
        guard let pem = String(data: data, encoding: .utf8) else {
            throw ASCError.invalidCredentials("the private key at \(url.path) is not UTF-8 text")
        }
        return ASCCredentials(keyId: keyId, issuerId: issuerId, privateKeyPEM: pem)
    }

    private static func expandTilde(_ path: String, home: URL) -> URL {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
