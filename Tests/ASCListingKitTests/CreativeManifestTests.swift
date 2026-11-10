@testable import ASCListingKit
import Foundation
import Testing

struct CreativeManifestTests {
    private func load(_ json: String) throws -> (Result<ResolvedManifest, any Error>, URL) {
        let directory = try makeTempDirectory()
        let url = directory.appending(path: "asc-listing.json")
        try write(json, to: url)
        return (Result { try PublishManifest.load(from: url) }, directory)
    }

    @Test func `a creative block with set mappings decodes and resolves its directory`() throws {
        let (result, directory) = try load("""
        {"bundleId":"a.b","platform":"IOS","creative":{"directory":"build/screenshots/creative",
         "sets":{"en":["en-US","en-CA","en-GB","en-AU"],"es":["es-MX","es-ES"]},
         "placements":{"PRODUCT_PAGE_HEADER_ASSET":"universal.png","APP_STORE_SEARCH_RESULTS_ASSET":"universal.png"}}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let creative = try #require(try result.get().creative)
        #expect(creative.directory == directory.appending(path: "build/screenshots/creative").standardized)
        #expect(creative.sets == .mapping(["en": ["en-US", "en-CA", "en-GB", "en-AU"], "es": ["es-MX", "es-ES"]]))
        #expect(creative.placements == ["PRODUCT_PAGE_HEADER_ASSET": "universal.png", "APP_STORE_SEARCH_RESULTS_ASSET": "universal.png"])
        #expect(try result.get().screenshots == nil)
    }

    @Test func `a creative block can use folders and keeps unknown placement types for later`() throws {
        let (result, directory) = try load(
            #"{"bundleId":"a.b","platform":"IOS","creative":{"directory":"art","sets":"folders","placements":{"SOMETHING_NEW":"x.png"}}}"#
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let creative = try #require(try result.get().creative)
        #expect(creative.sets == .folders)
        #expect(creative.placements == ["SOMETHING_NEW": "x.png"])
    }

    @Test func `the creative block is optional`() throws {
        let (result, directory) = try load(#"{"bundleId":"a.b","platform":"IOS"}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try result.get().creative == nil)
    }

    @Test(arguments: [
        (#"{}"#, "creative.placements"),
        (#"{"PRODUCT_PAGE_HEADER_ASSET":"en/universal.png"}"#, "creative.placements.PRODUCT_PAGE_HEADER_ASSET"),
        (#"{"PRODUCT_PAGE_HEADER_ASSET":""}"#, "creative.placements.PRODUCT_PAGE_HEADER_ASSET")
    ])
    func `placements need at least one plain file name`(placements: String, path: String) throws {
        let (result, directory) = try load(
            #"{"bundleId":"a.b","platform":"IOS","creative":{"directory":"art","sets":"folders","placements":\#(placements)}}"#
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ManifestError.self) { try result.get() }
        if case let .failure(error) = result {
            #expect("\(error)".contains(path))
        }
    }

    @Test func `a missing placements key names the path`() throws {
        let (result, directory) = try load(#"{"bundleId":"a.b","platform":"IOS","creative":{"directory":"art","sets":"folders"}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        if case let .failure(error) = result {
            #expect("\(error)".contains("creative.placements"))
        } else {
            Issue.record("expected an error")
        }
    }
}
