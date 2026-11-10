@testable import ASCListingKit
import Foundation
import Testing

struct ScreenshotFileTests {
    @Test func `reads size, alpha and a stable fingerprint without decoding pixels`() throws {
        let directory = try makeTempDirectory()
        let opaque = directory.appending(path: "panel-01.png")
        let translucent = directory.appending(path: "alpha.png")
        try ImageFixture.writePNG(width: 1320, height: 2868, to: opaque)
        try ImageFixture.writePNG(width: 20, height: 40, alpha: true, to: translucent)

        let file = try ScreenshotFile.read(opaque)
        #expect(file.width == 1320)
        #expect(file.height == 2868)
        #expect(file.sizeKey == "1320x2868")
        #expect(!file.hasAlpha)
        #expect(file.fileName == "panel-01.png")
        #expect(try file.byteCount == Data(contentsOf: opaque).count)
        #expect(file.fingerprint.hasPrefix("sha256:"))
        #expect(file.fingerprint.count == 7 + 64)
        #expect(try ScreenshotFile.read(opaque).fingerprint == file.fingerprint)

        let copy = directory.appending(path: "copy.png")
        try FileManager.default.copyItem(at: opaque, to: copy)
        #expect(try ScreenshotFile.read(copy).fingerprint == file.fingerprint)

        let alpha = try ScreenshotFile.read(translucent)
        #expect(alpha.hasAlpha)
        #expect(alpha.fingerprint != file.fingerprint)
    }

    @Test func `the fingerprint is lowercase sha256 hex of the bytes`() {
        let expected = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(ScreenshotFile.fingerprint(of: Data("abc".utf8)) == expected)
    }

    @Test func `a file that is not an image is unreadable`() throws {
        let url = try makeTempDirectory().appending(path: "broken.png")
        try write("not a png", to: url)
        #expect(throws: ASCError.self) { try ScreenshotFile.read(url) }
    }
}

struct LocalScreenshotsTests {
    private func config(_ directory: URL, _ sets: ScreenshotSets) -> ResolvedScreenshots {
        ResolvedScreenshots(directory: directory, sets: sets, placementGroups: [:])
    }

    @Test func `a mapped folder fans out to every locale in file name order`() throws {
        let directory = try makeTempDirectory()
        for name in ["panel-10.png", "panel-02.PNG", "panel-01.jpg"] {
            try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "en/\(name)"))
        }
        try write("hidden", to: directory.appending(path: "en/.DS_Store"))
        try write("notes", to: directory.appending(path: "en/readme.txt"))

        let result = try LocalScreenshots.load(config(directory, .mapping(["en": ["en-US", "en-GB", "en-AU"]])), localeFilter: nil)
        #expect(result.keys.sorted() == ["en-AU", "en-GB", "en-US"])
        let names = result["en-US"]?.map(\.fileName)
        #expect(names == ["panel-01.jpg", "panel-02.PNG", "panel-10.png"])
        #expect(result["en-GB"] == result["en-US"])
        #expect(result["en-AU"] == result["en-US"])
    }

    @Test func `folders mode uses each subfolder name as the locale`() throws {
        let directory = try makeTempDirectory()
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "ja/a.png"))
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "zh-Hant/a.png"))
        let result = try LocalScreenshots.load(config(directory, .folders), localeFilter: nil)
        #expect(result.keys.sorted() == ["ja", "zh-Hant"])
    }

    @Test func `the locale filter keeps only the chosen locales`() throws {
        let directory = try makeTempDirectory()
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "en/a.png"))
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "es/a.png"))
        let sets = ScreenshotSets.mapping(["en": ["en-US"], "es": ["es-MX", "es-ES"]])
        let result = try LocalScreenshots.load(config(directory, sets), localeFilter: ["es-ES", "fr"])
        #expect(result.keys.sorted() == ["es-ES"])
        let folders = try LocalScreenshots.load(config(directory, .folders), localeFilter: ["en"])
        #expect(folders.keys.sorted() == ["en"])
    }

    @Test func `a missing folder is named in the error`() throws {
        let directory = try makeTempDirectory()
        do {
            _ = try LocalScreenshots.load(config(directory, .mapping(["de": ["de-DE"]])), localeFilter: nil)
            Issue.record("expected an error")
        } catch let ASCError.screenshotsMisconfigured(reason) {
            #expect(reason.contains("/de"))
        }
    }

    @Test func `an empty folder is an error`() throws {
        let directory = try makeTempDirectory()
        try write("x", to: directory.appending(path: "en/readme.txt"))
        #expect(throws: ASCError.self) {
            try LocalScreenshots.load(config(directory, .mapping(["en": ["en-US"]])), localeFilter: nil)
        }
    }

    @Test func `every image with alpha is listed`() throws {
        let directory = try makeTempDirectory()
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "en/ok.png"))
        try ImageFixture.writePNG(width: 12, height: 26, alpha: true, to: directory.appending(path: "en/bad-1.png"))
        try ImageFixture.writePNG(width: 12, height: 26, alpha: true, to: directory.appending(path: "es/bad-2.png"))
        let sets = ScreenshotSets.mapping(["en": ["en-US"], "es": ["es-MX"]])
        do {
            _ = try LocalScreenshots.load(config(directory, sets), localeFilter: nil)
            Issue.record("expected an error")
        } catch let ASCError.screenshotsInvalid(files) {
            #expect(files == ["en/bad-1.png", "es/bad-2.png"])
            #expect(ASCError.screenshotsInvalid(files).description.contains("alpha channel"))
        }
    }

    @Test func `one locale mapped from two folders is refused`() throws {
        let directory = try makeTempDirectory()
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "a/x.png"))
        try ImageFixture.writePNG(width: 12, height: 26, to: directory.appending(path: "b/x.png"))
        #expect(throws: ASCError.self) {
            try LocalScreenshots.load(config(directory, .mapping(["a": ["en-US"], "b": ["en-US"]])), localeFilter: nil)
        }
    }
}
