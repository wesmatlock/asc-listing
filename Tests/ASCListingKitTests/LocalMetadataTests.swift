@testable import ASCListingKit
import Foundation
import Testing

struct LocalMetadataTests {
    @Test func `one trailing newline is stripped and internal blank lines kept`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("My App\n", to: root.appending(path: "en-US/name.txt"))
        try write("Line one\r\n\r\nLine three\n\n", to: root.appending(path: "en-US/description.txt"))
        try write("windows\r\n", to: root.appending(path: "en-US/subtitle.txt"))
        let (metadata, warnings) = try LocalMetadata.load(directory: root)
        #expect(metadata.locales["en-US"]?[.name] == "My App")
        #expect(metadata.locales["en-US"]?[.description] == "Line one\r\n\r\nLine three\n")
        #expect(metadata.locales["en-US"]?[.subtitle] == "windows")
        #expect(metadata.locales["en-US"]?[.keywords] == nil)
        #expect(warnings.isEmpty)
    }

    @Test func `copyright, unknown files and stray top level files are read or warned`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("2026 Wesley\n", to: root.appending(path: "copyright.txt"))
        try write("x", to: root.appending(path: "README.md"))
        try write("x", to: root.appending(path: "ja/notes.txt"))
        try write("日本語", to: root.appending(path: "ja/name.txt"))
        let (metadata, warnings) = try LocalMetadata.load(directory: root)
        #expect(metadata.copyright == "2026 Wesley")
        #expect(metadata.locales.keys.sorted() == ["ja"])
        #expect(warnings.contains { $0.contains("ja/notes.txt") })
        #expect(warnings.contains { $0.contains("README.md") })
    }

    @Test func `every over limit field is collected`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "k", count: 104), to: root.appending(path: "ja/keywords.txt"))
        try write(String(repeating: "n", count: 31), to: root.appending(path: "ja/name.txt"))
        try write(String(repeating: "s", count: 31), to: root.appending(path: "fr/subtitle.txt"))
        try write(String(repeating: "p", count: 171), to: root.appending(path: "fr/promotional_text.txt"))
        try write(String(repeating: "d", count: 4001), to: root.appending(path: "fr/description.txt"))
        try write(String(repeating: "あ", count: 100), to: root.appending(path: "es/keywords.txt"))
        do {
            _ = try LocalMetadata.load(directory: root)
            Issue.record("expected a validation error")
        } catch let ASCError.metadataInvalid(violations) {
            #expect(violations.contains("ja keywords: 104 > 100"))
            #expect(violations.contains("ja name: 31 > 30"))
            #expect(violations.contains("fr subtitle: 31 > 30"))
            #expect(violations.contains("fr promotionalText: 171 > 170"))
            #expect(violations.contains("fr description: 4001 > 4000"))
            #expect(violations.count == 5)
        }
    }

    @Test func `an empty file counts as absent and is named in a warning`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("\n", to: root.appending(path: "en-US/keywords.txt"))
        try write("", to: root.appending(path: "en-US/promotional_text.txt"))
        try write("\r\n", to: root.appending(path: "copyright.txt"))
        try write("Name", to: root.appending(path: "en-US/name.txt"))
        let (metadata, warnings) = try LocalMetadata.load(directory: root)
        #expect(metadata.locales["en-US"] == [.name: "Name"])
        #expect(metadata.copyright == nil)
        #expect(warnings.contains { $0.contains("en-US/keywords.txt") })
        #expect(warnings.contains { $0.contains("en-US/promotional_text.txt") })
        #expect(warnings.contains { $0.contains("copyright.txt") })
        #expect(warnings.count == 3)
    }

    @Test func `a missing directory is an error`() {
        #expect(throws: ASCError.self) {
            try LocalMetadata.load(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        }
    }
}
