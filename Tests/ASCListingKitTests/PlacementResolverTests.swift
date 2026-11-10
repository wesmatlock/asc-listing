@testable import ASCListingKit
import Foundation
import Testing

struct PlacementResolverTests {
    @Test func `the 6.9 inch iPhone size resolves to the dynamic island large group`() throws {
        let resolver = try PlacementResolver(refData: fixtureRefData(), pins: [:])
        let target = try resolver.resolve(width: 1320, height: 2868)
        #expect(target == PlacementTarget(
            group: "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE",
            specID: "bd402f1a-26ee-5b83-9dd7-972c60c43d47",
            maxCount: 10
        ))
        let older = try resolver.resolve(width: 1290, height: 2796)
        #expect(older.group == "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE")
        #expect(older.specID != target.specID)
    }

    @Test func `an unknown size is unsupported`() throws {
        let resolver = try PlacementResolver(refData: fixtureRefData(), pins: [:])
        do {
            _ = try resolver.resolve(width: 123, height: 456)
            Issue.record("expected an error")
        } catch let ASCError.unsupportedScreenshotSize(size) {
            #expect(size == "123x456")
        }
    }

    private func ambiguousRefData() throws -> RefData {
        let json = """
        {
          "features": [{"featureId": "APP_STORE_VERSIONS", "placementPolicies": [
            {"placementType": "APP_SCREENSHOT", "groupLimits": [
              {"groupIds": ["GROUP_A"], "maxCount": 10},
              {"groupIds": ["GROUP_B"], "maxCount": 5}
            ]}
          ]}],
          "placementProfileGroups": [],
          "imageSpecs": [
            {"specId": "range", "dimensions": {"minWidth": 100, "maxWidth": 300, "minHeight": 100, "maxHeight": 300},
             "compatiblePlacementTypes": ["APP_SCREENSHOT"], "extra": true},
            {"specId": "exact", "dimensions": {"minWidth": 200, "maxWidth": 200, "minHeight": 200, "maxHeight": 200},
             "compatiblePlacementTypes": ["APP_SCREENSHOT"]}
          ],
          "placementTypes": [{"placementTypeId": "APP_SCREENSHOT", "specMappings": [
            {"placementGroupId": "GROUP_A", "specs": ["range", "exact"]},
            {"placementGroupId": "GROUP_B", "specs": ["range"]},
            {"placementGroupId": "GROUP_C", "specs": ["exact"]}
          ]}]
        }
        """
        return try JSONDecoder().decode(RefData.self, from: Data(json.utf8))
    }

    @Test func `several groups need a pin`() throws {
        let refData = try ambiguousRefData()
        do {
            _ = try PlacementResolver(refData: refData, pins: [:]).resolve(width: 200, height: 200)
            Issue.record("expected an error")
        } catch let ASCError.ambiguousPlacement(size, candidates) {
            #expect(size == "200x200")
            #expect(candidates == ["GROUP_A", "GROUP_B"])
        }
        let pinned = try PlacementResolver(refData: refData, pins: ["200x200": "GROUP_B"]).resolve(width: 200, height: 200)
        #expect(pinned == PlacementTarget(group: "GROUP_B", specID: "range", maxCount: 5))
        let preferExact = try PlacementResolver(refData: refData, pins: ["200x200": "GROUP_A"]).resolve(width: 200, height: 200)
        #expect(preferExact == PlacementTarget(group: "GROUP_A", specID: "exact", maxCount: 10))
    }

    @Test func `a pin outside the candidates is still ambiguous`() throws {
        let resolver = try PlacementResolver(refData: ambiguousRefData(), pins: ["200x200": "GROUP_C"])
        #expect(throws: ASCError.self) { try resolver.resolve(width: 200, height: 200) }
    }

    @Test func `a spec whose minimum exceeds its maximum matches nothing`() {
        let inverted = RefData.Dimensions(minWidth: 300, maxWidth: 100, minHeight: 300, maxHeight: 100)
        #expect(!inverted.contains(width: 200, height: 200))
        #expect(!inverted.contains(width: 300, height: 300))
        let range = RefData.Dimensions(minWidth: 100, maxWidth: 300, minHeight: 100, maxHeight: 300)
        #expect(range.contains(width: 100, height: 300))
        #expect(!range.contains(width: 301, height: 200))
    }
}
