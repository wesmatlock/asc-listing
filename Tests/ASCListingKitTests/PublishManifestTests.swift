@testable import ASCListingKit
import Foundation
import Testing

struct PublishManifestTests {
    private func manifest(_ json: String) throws -> (ResolvedManifest, URL) {
        let directory = try makeTempDirectory()
        let url = directory.appending(path: "asc-listing.json")
        try write(json, to: url)
        return try (PublishManifest.load(from: url), directory)
    }

    @Test func `a full manifest decodes and resolves relative paths`() throws {
        let (resolved, directory) = try manifest("""
        {"bundleId":"com.example.MyApp","platform":"IOS","version":"1.0","metadata":"build/appstore/metadata",
         "screenshots":{"directory":"build/screenshots/final",
         "sets":{"en":["en-US"],"es":["es-MX","es-ES"]},
         "placementGroups":{"1320x2868":"IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"}}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(resolved.bundleId == "com.example.MyApp")
        #expect(resolved.platform == .ios)
        #expect(resolved.version == "1.0")
        #expect(resolved.metadataDirectory == directory.appending(path: "build/appstore/metadata").standardized)
        #expect(resolved.screenshots?.directory.lastPathComponent == "final")
        #expect(resolved.screenshots?.sets == .mapping(["en": ["en-US"], "es": ["es-MX", "es-ES"]]))
        #expect(resolved.screenshots?.placementGroups["1320x2868"] == "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE")
    }

    @Test func `absolute and tilde paths are kept`() throws {
        let (resolved, directory) = try manifest(
            #"{"bundleId":"a.b","platform":"MAC_OS","metadata":"/abs/meta","screenshots":{"directory":"~/shots","sets":"folders"}}"#
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(resolved.metadataDirectory?.path == "/abs/meta")
        #expect(resolved.screenshots?.directory.path == (("~/shots" as NSString).expandingTildeInPath))
        #expect(resolved.screenshots?.sets == .folders)
        #expect(resolved.screenshots?.placementGroups.isEmpty == true)
        #expect(resolved.version == nil)
    }

    @Test func `optional blocks may be missing`() throws {
        let (resolved, directory) = try manifest(#"{"bundleId":"a.b","platform":"TV_OS"}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(resolved.metadataDirectory == nil)
        #expect(resolved.screenshots == nil)
    }

    @Test func `an unknown platform is an error`() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "m.json")
        try write(#"{"bundleId":"a.b","platform":"WATCH_OS"}"#, to: url)
        #expect {
            try PublishManifest.load(from: url)
        } throws: { error in
            "\(error)".contains("WATCH_OS")
        }
    }

    @Test func `a bad sets string is an error naming the path`() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "m.json")
        try write(#"{"bundleId":"a.b","platform":"IOS","screenshots":{"directory":"x","sets":"nope"}}"#, to: url)
        #expect {
            try PublishManifest.load(from: url)
        } throws: { error in
            "\(error)".contains("screenshots.sets") && "\(error)".contains("nope")
        }
    }

    @Test func `unreadable and invalid files report their cause`() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ManifestError.self) { try PublishManifest.load(from: directory.appending(path: "missing.json")) }
        let url = directory.appending(path: "m.json")
        try write(#"{"platform":"IOS"}"#, to: url)
        #expect {
            try PublishManifest.load(from: url)
        } throws: { error in
            "\(error)".contains("bundleId")
        }
    }
}
