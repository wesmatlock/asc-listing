@testable import ASCListingKit
import Foundation
import Testing

struct ScreenshotPlanTests {
    private let group = "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"
    private let spec = "bd402f1a-26ee-5b83-9dd7-972c60c43d47"

    private func files(_ count: Int) -> [ScreenshotFile] {
        (1 ... count).map { screenshot(String(format: "panel-%02d.png", $0)) }
    }

    private func placed(_ files: [ScreenshotFile]) -> [CurrentPlacement] {
        files.enumerated().map { CurrentPlacement(id: "p\($0.offset)", imageReferenceName: $0.element.fingerprint) }
    }

    private func plan(
        _ desired: [String: [ScreenshotFile]],
        current: [String: CurrentLocaleState],
        library: [String: LibraryImage] = [:]
    ) throws -> ScreenshotPlan {
        try ScreenshotPlan.make(
            desired: desired,
            resolver: PlacementResolver(refData: fixtureRefData(), pins: [:]),
            current: current,
            library: library
        )
    }

    @Test func `the same images in the same order are unchanged`() throws {
        let local = files(3)
        let result = try plan(["en-US": local], current: ["en-US": CurrentLocaleState(localizationID: "l1", groups: [group: placed(local)])])
        #expect(result.groups.map(\.action) == [.unchanged])
        #expect(result.groups.first?.group == group)
        #expect(result.uploads.isEmpty)
        #expect(result.reuses == 0)
        #expect(result.localizationsToCreate.isEmpty)
        #expect(!result.hasChanges)
    }

    @Test func `a different order or a changed file replaces the group`() throws {
        let local = files(3)
        let reordered = try plan(
            ["en-US": local],
            current: ["en-US": CurrentLocaleState(localizationID: "l1", groups: [group: placed(local.reversed())])]
        )
        #expect(reordered.groups.map(\.action) == [.replace])

        var changed = local
        changed[1] = screenshot("panel-02.png", fingerprint: "sha256:new")
        let edited = try plan(
            ["en-US": changed],
            current: ["en-US": CurrentLocaleState(localizationID: "l1", groups: [group: placed(local)])]
        )
        #expect(edited.groups.map(\.action) == [.replace])
        #expect(edited.groups.first?.current.count == 3)
        #expect(edited.uploads.map(\.fingerprint) == local.map(\.fingerprint).enumerated().map { $0.offset == 1 ? "sha256:new" : $0.element })
    }

    @Test func `a locale with no localization is created and filled`() throws {
        let result = try plan(["es-MX": files(2)], current: ["es-MX": CurrentLocaleState(localizationID: nil)])
        #expect(result.localizationsToCreate == ["es-MX"])
        #expect(result.groups.map(\.action) == [.replace])
        let text = result.render(primaryLocale: "en-US")
        #expect(text.contains("es-MX  | \(group) | 2     | replace (0 → 2)"))
        #expect(text.contains("2 files to upload, 0 already in the asset library"))
        #expect(text.contains("1 localizations to create"))
        let missing = try plan(["es-MX": files(2)], current: [:])
        #expect(missing.localizationsToCreate == ["es-MX"])
    }

    @Test func `ready library images are reused and unfinished ones uploaded once`() throws {
        let local = files(4)
        let library = [
            local[0].fingerprint: LibraryImage(id: "i0", state: "PREPARE_FOR_SUBMISSION", specID: spec),
            local[1].fingerprint: LibraryImage(id: "i1", state: "UPLOAD_COMPLETE"),
            local[2].fingerprint: LibraryImage(id: "i2", state: "AWAITING_UPLOAD"),
            local[3].fingerprint: LibraryImage(id: "i3", state: "FAILED")
        ]
        let result = try plan(
            ["en-US": local, "en-GB": local],
            current: ["en-US": CurrentLocaleState(localizationID: "a"), "en-GB": CurrentLocaleState(localizationID: "b")],
            library: library
        )
        #expect(result.reuses == 2)
        #expect(result.uploads.map(\.fileName) == ["panel-03.png", "panel-04.png"])
        #expect(result.assets.map(\.specID) == Array(repeating: spec, count: 4))
        let text = result.render(primaryLocale: "en-US")
        #expect(text.contains("2 files to upload, 2 already in the asset library, 0 localizations to create"))
        let rows = text.split(separator: "\n")
        #expect(rows[2].hasPrefix("en-US*"))
    }

    @Test func `unchanged groups need no assets`() throws {
        let local = files(2)
        let result = try plan(
            ["en-US": local, "fr-FR": local],
            current: [
                "en-US": CurrentLocaleState(localizationID: "a", groups: [group: placed(local)]),
                "fr-FR": CurrentLocaleState(localizationID: "b")
            ]
        )
        #expect(result.groups.map(\.locale) == ["en-US", "fr-FR"])
        #expect(result.groups.map(\.action) == [.unchanged, .replace])
        #expect(result.uploads.count == 2)
    }

    @Test func `more than the group limit is refused`() throws {
        do {
            _ = try plan(["en-US": files(11)], current: [:])
            Issue.record("expected an error")
        } catch let ASCError.tooManyScreenshots(locale, refused, count, max) {
            #expect(locale == "en-US")
            #expect(refused == group)
            #expect(count == 11)
            #expect(max == 10)
        }
    }
}
