@testable import ASCListingKit
import Foundation
import Testing

struct VersionResolutionTests {
    private func manifest(version: String?) -> ResolvedManifest {
        ResolvedManifest(
            manifestURL: URL(fileURLWithPath: "/tmp/asc-listing.json"),
            bundleId: "net.example.App",
            platform: .ios,
            version: version,
            metadataDirectory: nil,
            screenshots: nil
        )
    }

    @Test func `flag beats the manifest`() throws {
        #expect(try PublishSession.resolveVersion(flag: "2.0", manifest: manifest(version: "1.0")) == "2.0")
    }

    @Test func `manifest version is the fallback`() throws {
        #expect(try PublishSession.resolveVersion(flag: nil, manifest: manifest(version: "1.0")) == "1.0")
    }

    @Test func `neither is an error`() {
        #expect(throws: ASCError.self) { try PublishSession.resolveVersion(flag: nil, manifest: manifest(version: nil)) }
    }
}
