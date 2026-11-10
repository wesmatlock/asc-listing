@testable import ASCListingKit
import Foundation
import Testing

let headerType = "PRODUCT_PAGE_HEADER_ASSET"
let searchType = "APP_STORE_SEARCH_RESULTS_ASSET"
let universalSpec = "c8f4e2b1-7a3d-5c9e-8b6f-2d1a0e9c8b7a"

struct CreativeResolverTests {
    private func resolver(_ placementType: String) throws -> PlacementResolver {
        try PlacementResolver(refData: fixtureRefData(), pins: [:], placementType: placementType)
    }

    @Test(arguments: [headerType, searchType])
    func `the universal size fills either placement from the default profile`(placementType: String) throws {
        let target = try resolver(placementType).resolve(width: 5244, height: 2950)
        #expect(target == PlacementTarget(group: "DEFAULT_PROFILE", specID: universalSpec, maxCount: 1))
    }

    @Test func `the wide header size resolves for the header and is refused for search`() throws {
        let header = try resolver(headerType).resolve(width: 3840, height: 1646)
        #expect(header == PlacementTarget(group: "DEFAULT_PROFILE", specID: "1eb43b80-e0b7-4d96-bd32-47a42a8c5fed", maxCount: 1))
        do {
            _ = try resolver(searchType).resolve(width: 3840, height: 1646)
            Issue.record("expected an error")
        } catch let ASCError.unsupportedAssetSize(size, placementType, accepted) {
            #expect(size == "3840x1646")
            #expect(placementType == searchType)
            #expect(accepted.contains("1920–3840x1280–2560 (3:2)"))
            #expect(accepted.contains("5244x2950"))
        }
    }

    @Test func `a three by two size inside the range resolves for search only`() throws {
        let search = try resolver(searchType).resolve(width: 2400, height: 1600)
        #expect(search == PlacementTarget(group: "DEFAULT_PROFILE", specID: "d2ffa3b7-6c55-5cdf-8512-229d92791333", maxCount: 1))
        #expect(throws: ASCError.self) { try resolver(headerType).resolve(width: 2400, height: 1600) }
    }

    @Test func `a screenshot size is refused for the header and the message names the placement type`() throws {
        do {
            _ = try resolver(headerType).resolve(width: 1320, height: 2868)
            Issue.record("expected an error")
        } catch let error as ASCError {
            guard case let .unsupportedAssetSize(size, placementType, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(size == "1320x2868")
            #expect(placementType == headerType)
            #expect(error.description.contains(headerType))
            #expect(error.description.contains("1320x2868"))
        }
    }

    @Test func `the screenshot resolver ignores creative specs`() throws {
        #expect(throws: ASCError.self) { try PlacementResolver(refData: fixtureRefData(), pins: [:]).resolve(width: 5244, height: 2950) }
    }

    @Test func `a JPEG is refused where the spec accepts only PNG`() throws {
        let jpeg = screenshot("universal.jpg", width: 5244, height: 2950).withMimeType("image/jpeg")
        do {
            _ = try resolver(headerType).resolve(jpeg)
            Issue.record("expected an error")
        } catch let error as ASCError {
            guard case let .unsupportedImageFormat(fileName, mimeType, size, spec, accepted) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(fileName == "universal.jpg")
            #expect(mimeType == "image/jpeg")
            #expect(size == "5244x2950")
            #expect(spec == "i5244x2950a0")
            #expect(accepted == ["image/png"])
            #expect(error.description.contains("accepts only image/png"))
        }
        let png = screenshot("universal.png", width: 5244, height: 2950).withMimeType("image/png")
        #expect(try resolver(searchType).resolve(png).specID == universalSpec)
        let searchJPEG = screenshot("search.jpg", width: 2400, height: 1600).withMimeType("image/jpeg")
        #expect(try resolver(searchType).resolve(searchJPEG).group == "DEFAULT_PROFILE")
    }

    @Test func `a placement type must accept creative assets`() throws {
        let refData = try fixtureRefData()
        try PlacementResolver.checkPlacementType(headerType, category: AssetRequests.creativeCategory, refData: refData)
        for bad in ["APP_SCREENSHOT", "PRODUCT_PAGE_HEADER"] {
            do {
                try PlacementResolver.checkPlacementType(bad, category: AssetRequests.creativeCategory, refData: refData)
                Issue.record("expected an error for \(bad)")
            } catch let error as ASCError {
                guard case let .unknownPlacementType(type, _, known) = error else {
                    Issue.record("unexpected \(error)")
                    return
                }
                #expect(type == bad)
                #expect(known.contains(headerType) && known.contains(searchType))
                #expect(!known.contains("APP_SCREENSHOT"))
                #expect(error.description.contains(bad))
            }
        }
    }
}

extension ScreenshotFile {
    func withMimeType(_ mimeType: String) -> ScreenshotFile {
        ScreenshotFile(
            url: url,
            fileName: fileName,
            width: width,
            height: height,
            hasAlpha: hasAlpha,
            byteCount: byteCount,
            fingerprint: fingerprint,
            mimeType: mimeType
        )
    }
}
