import Foundation

public struct PublishSession: Sendable {
    public let manifest: ResolvedManifest
    public let client: ASCClient
    public let lookup: AppStoreLookup
    public let log: PublishLog

    public init(manifest: ResolvedManifest, client: ASCClient, log: PublishLog) {
        self.manifest = manifest
        self.client = client
        lookup = AppStoreLookup(client: client)
        self.log = log
    }

    public static func make(
        manifestPath: String,
        verbose: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PublishSession {
        let manifest = try PublishManifest.load(from: URL(fileURLWithPath: manifestPath))
        let credentials = try ASCCredentials.resolve(environment: environment)
        let log = PublishLog(verbose: verbose)
        let client = try ASCClient(signer: JWTSigner(credentials: credentials), log: log)
        return PublishSession(manifest: manifest, client: client, log: log)
    }

    public func resolveVersion(flag: String?) throws -> String {
        try Self.resolveVersion(flag: flag, manifest: manifest)
    }

    public static func resolveVersion(flag: String?, manifest: ResolvedManifest) throws -> String {
        if let flag, !flag.isEmpty {
            return flag
        }
        if let version = manifest.version, !version.isEmpty {
            return version
        }
        throw ASCError.versionRequired
    }
}
