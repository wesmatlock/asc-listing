@testable import ASCListingKit
import Foundation
import Testing

struct PublishRunTests {
    private func session(root: URL, lines: LineRecorder) throws -> PublishSession {
        let manifest = ResolvedManifest(
            manifestURL: root.appending(path: "asc-listing.json"),
            bundleId: "com.example.MyApp",
            platform: .ios,
            version: "1.0",
            metadataDirectory: root.appending(path: "metadata"),
            screenshots: ResolvedScreenshots(
                directory: root.appending(path: "shots"),
                sets: .mapping(["en": ["en-US"]]),
                placementGroups: [:]
            )
        )
        let client = try ASCClient(
            transport: ScriptedTransport([]),
            signer: JWTSigner(credentials: makeCredentials()),
            log: .silent,
            sleeper: SleepRecorder().sleeper
        )
        return PublishSession(manifest: manifest, client: client, log: lines.log)
    }

    @Test func `a locale filter notes the copyright and names a locale with no screenshot set`() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("2026 Me\n", to: root.appending(path: "metadata/copyright.txt"))
        try write("Name\n", to: root.appending(path: "metadata/en-US/name.txt"))
        try ImageFixture.writePNG(width: 20, height: 40, to: root.appending(path: "shots/en/panel-01.png"))
        let lines = LineRecorder()
        let run = try PublishRun(session: session(root: root, lines: lines), emit: { _ in })
        await #expect(throws: ASCError.self) {
            try await run.run([.metadata, .screenshots], options: PublishOptions(version: "1.0", locales: ["en-US", "fr-CA"]))
        }
        #expect(lines.lines.contains("note: copyright is version-wide and is only sent without --locale"))
        #expect(lines.lines.contains("warning: --locale fr-CA matches no screenshot set in the manifest"))
        #expect(!lines.lines.contains { $0.contains("--locale en-US") })
    }

    @Test func `without a locale filter there is no copyright note`() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("2026 Me\n", to: root.appending(path: "metadata/copyright.txt"))
        let lines = LineRecorder()
        let run = try PublishRun(session: session(root: root, lines: lines), emit: { _ in })
        await #expect(throws: ASCError.self) {
            try await run.run([.metadata], options: PublishOptions(version: "1.0"))
        }
        #expect(lines.lines.isEmpty)
    }
}
