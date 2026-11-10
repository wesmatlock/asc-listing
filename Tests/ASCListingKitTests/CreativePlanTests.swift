@testable import ASCListingKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

struct CreativePlanTests {
    private let header = PlacementSlot(placementType: headerType, group: "DEFAULT_PROFILE")
    private let search = PlacementSlot(placementType: searchType, group: "DEFAULT_PROFILE")

    private func universal(_ fingerprint: String = "sha256:universal") -> ScreenshotFile {
        screenshot("universal.png", width: 5244, height: 2950, fingerprint: fingerprint).withMimeType("image/png")
    }

    private func both(_ file: ScreenshotFile) -> [CreativeAsset] {
        [CreativeAsset(placementType: headerType, file: file), CreativeAsset(placementType: searchType, file: file)]
    }

    private func placed(_ fingerprint: String) -> [PlacementSlot: [CurrentPlacement]] {
        [header: [CurrentPlacement(id: "h", imageReferenceName: fingerprint)], search: [CurrentPlacement(id: "s", imageReferenceName: fingerprint)]]
    }

    private func plan(
        _ desired: [String: [CreativeAsset]],
        current: [String: CurrentLocaleState],
        library: [String: LibraryImage] = [:]
    ) throws -> ScreenshotPlan {
        try ScreenshotPlan.makeCreative(desired: desired, refData: fixtureRefData(), current: current, library: library)
    }

    @Test func `one file for both placements uploads once and places twice per locale`() throws {
        let file = universal()
        let result = try plan(
            ["en-US": both(file), "en-GB": both(file)],
            current: ["en-US": CurrentLocaleState(localizationID: "a"), "en-GB": CurrentLocaleState(localizationID: "b")]
        )
        #expect(result.groups.count == 4)
        #expect(result.groups.map(\.slot) == [header, search, header, search])
        #expect(result.groups.allSatisfy { $0.action == .replace && $0.desired == [file] })
        #expect(result.assets.count == 1)
        #expect(result.uploads == [file])
        #expect(result.assets.first?.specID == universalSpec)
        #expect(result.assets.first?.category == "CREATIVE_ASSETS")
        #expect(result.category == "CREATIVE_ASSETS")
        let lines = result.renderCreative(primaryLocale: "en-US").split(separator: "\n").map(String.init)
        #expect(lines[0] == "locale | placement                      | file          | action")
        #expect(lines[2] == "en-US* | PRODUCT_PAGE_HEADER_ASSET      | universal.png | replace (0 → 1)")
        #expect(lines[3] == "en-US* | APP_STORE_SEARCH_RESULTS_ASSET | universal.png | replace (0 → 1)")
        #expect(lines[4].hasPrefix("en-GB  | PRODUCT_PAGE_HEADER_ASSET"))
        #expect(lines.last == "1 files to upload, 0 already in the asset library, 0 localizations to create")
    }

    @Test func `a second run with the same file is unchanged`() throws {
        let file = universal()
        let result = try plan(["en-US": both(file)], current: ["en-US": CurrentLocaleState(localizationID: "a", placements: placed(file.fingerprint))])
        #expect(result.groups.map(\.action) == [.unchanged, .unchanged])
        #expect(result.assets.isEmpty)
        #expect(!result.hasChanges)
        #expect(result.renderCreative(primaryLocale: "en-US").contains("en-US* | PRODUCT_PAGE_HEADER_ASSET      | universal.png | unchanged"))
    }

    @Test func `a changed file replaces both placements`() throws {
        let changed = universal("sha256:new")
        let result = try plan(["en-US": both(changed)], current: ["en-US": CurrentLocaleState(localizationID: "a", placements: placed("sha256:old"))])
        #expect(result.groups.map(\.action) == [.replace, .replace])
        let current = result.groups.map(\.current)
        #expect(current == [[CurrentPlacement(id: "h", imageReferenceName: "sha256:old")], [CurrentPlacement(id: "s", imageReferenceName: "sha256:old")]])
        #expect(result.uploads.map(\.fingerprint) == ["sha256:new"])
    }

    @Test func `only a creative image with the same bytes is reused`() throws {
        let file = universal()
        let current = ["es-MX": CurrentLocaleState(localizationID: nil)]
        let screenshotImage = LibraryImage(id: "shot", state: "APPROVED", specID: universalSpec, category: AssetRequests.screenshotCategory)
        let mismatched = try plan(["es-MX": both(file)], current: current, library: [file.fingerprint: screenshotImage])
        #expect(mismatched.assets.first?.existing == nil)
        #expect(mismatched.uploads == [file])
        #expect(mismatched.reuses == 0)
        #expect(mismatched.localizationsToCreate == ["es-MX"])

        let creativeImage = LibraryImage(id: "art", state: "APPROVED", specID: universalSpec, category: AssetRequests.creativeCategory)
        let reused = try plan(["es-MX": both(file)], current: current, library: [file.fingerprint: creativeImage])
        #expect(reused.assets.first?.existing == creativeImage)
        #expect(reused.uploads.isEmpty)
        #expect(reused.renderCreative(primaryLocale: "en-US").hasSuffix("0 files to upload, 1 already in the asset library, 1 localizations to create"))
    }

    @Test func `a screenshot plan does not reuse a creative image`() throws {
        let shot = screenshot("panel-01.png")
        let result = try ScreenshotPlan.make(
            desired: ["en-US": [shot]],
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: ["en-US": CurrentLocaleState(localizationID: "a")],
            library: [shot.fingerprint: LibraryImage(id: "art", state: "APPROVED", category: AssetRequests.creativeCategory)]
        )
        #expect(result.uploads == [shot])
    }

    @Test func `an unknown placement type fails when the plan is resolved`() throws {
        let file = universal()
        do {
            _ = try plan(["en-US": [CreativeAsset(placementType: "PRODUCT_PAGE_BANNER", file: file)]], current: [:])
            Issue.record("expected an error")
        } catch let ASCError.unknownPlacementType(type, category, known) {
            #expect(type == "PRODUCT_PAGE_BANNER")
            #expect(category == "CREATIVE_ASSETS")
            #expect(known.contains(headerType))
        }
    }

    @Test func `separate header and search files each resolve to their own spec`() throws {
        let wide = screenshot("header.png", width: 3840, height: 1646).withMimeType("image/png")
        let landscape = screenshot("search.png", width: 2400, height: 1600).withMimeType("image/png")
        let result = try plan(
            ["en-US": [CreativeAsset(placementType: headerType, file: wide), CreativeAsset(placementType: searchType, file: landscape)]],
            current: ["en-US": CurrentLocaleState(localizationID: "a")]
        )
        #expect(result.assets.map(\.file.fileName) == ["header.png", "search.png"])
        #expect(result.assets.map(\.specID) == ["1eb43b80-e0b7-4d96-bd32-47a42a8c5fed", "d2ffa3b7-6c55-5cdf-8512-229d92791333"])
    }
}

struct LocalCreativeTests {
    private func config(_ root: URL, sets: ScreenshotSets, placements: [String: String]? = nil) -> ResolvedCreative {
        ResolvedCreative(
            directory: root.appending(path: "creative"),
            sets: sets,
            placements: placements ?? [headerType: "universal.png", searchType: "universal.png"]
        )
    }

    @Test func `each set folder fills its locales and a shared file is read once`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ImageFixture.writePNG(width: 60, height: 40, to: root.appending(path: "creative/en/universal.png"))
        try ImageFixture.writePNG(width: 60, height: 40, shade: 0.8, to: root.appending(path: "creative/es/universal.png"))
        let loaded = try LocalCreative.load(config(root, sets: .mapping(["en": ["en-US", "en-GB"], "es": ["es-MX"]])), localeFilter: nil)
        #expect(loaded.keys.sorted() == ["en-GB", "en-US", "es-MX"])
        let english = try #require(loaded["en-US"])
        #expect(english.map(\.placementType) == [searchType, headerType])
        #expect(english[0].file == english[1].file)
        #expect(english[0].file.mimeType == "image/png")
        #expect(loaded["en-GB"] == english)
        #expect(loaded["es-MX"]?.first?.file.fingerprint != english[0].file.fingerprint)

        let filtered = try LocalCreative.load(config(root, sets: .mapping(["en": ["en-US", "en-GB"], "es": ["es-MX"]])), localeFilter: ["es-MX"])
        #expect(filtered.keys.sorted() == ["es-MX"])
    }

    @Test func `folders mode treats each subfolder as a locale`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ImageFixture.writePNG(width: 60, height: 40, to: root.appending(path: "creative/ja/universal.png"))
        try ImageFixture.writePNG(width: 60, height: 40, to: root.appending(path: "creative/ko/universal.png"))
        let loaded = try LocalCreative.load(config(root, sets: .folders), localeFilter: nil)
        #expect(loaded.keys.sorted() == ["ja", "ko"])
    }

    @Test func `a missing file names the placement and the path`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ImageFixture.writePNG(width: 60, height: 40, to: root.appending(path: "creative/en/universal.png"))
        let placements = [headerType: "universal.png", searchType: "search.png"]
        #expect {
            try LocalCreative.load(config(root, sets: .mapping(["en": ["en-US"]]), placements: placements), localeFilter: nil)
        } throws: { error in
            "\(error)".contains("Creative assets: \(searchType) needs") && "\(error)".contains("en/search.png")
        }
    }

    @Test func `an image with alpha is refused`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ImageFixture.writePNG(width: 60, height: 40, alpha: true, to: root.appending(path: "creative/en/universal.png"))
        do {
            _ = try LocalCreative.load(config(root, sets: .mapping(["en": ["en-US"]])), localeFilter: nil)
            Issue.record("expected an error")
        } catch let ASCError.screenshotsInvalid(files) {
            #expect(files == ["en/universal.png"])
        }
    }

    @Test func `a JPEG at the universal size is refused before anything is sent`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "creative/en/universal.jpg")
        try writeJPEG(width: 5244, height: 2950, to: url)
        let loaded = try LocalCreative.load(
            config(root, sets: .mapping(["en": ["en-US"]]), placements: [headerType: "universal.jpg", searchType: "universal.jpg"]),
            localeFilter: nil
        )
        #expect(loaded["en-US"]?.first?.file.mimeType == "image/jpeg")
        #expect {
            try ScreenshotPlan.makeCreative(desired: loaded, refData: fixtureRefData(), current: [:], library: [:])
        } throws: { error in
            "\(error)".contains("universal.jpg is image/jpeg, but App Store Connect accepts only image/png at 5244x2950")
        }
    }

    private func writeJPEG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
