@testable import ASCListingKit
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

enum ImageFixture {
    static func writePNG(width: Int, height: Int, alpha: Bool = false, shade: CGFloat = 0.3, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info.rawValue
        ))
        context.setFillColor(red: shade, green: 0.5, blue: 0.2, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

func screenshot(_ name: String, width: Int = 1320, height: Int = 2868, fingerprint: String? = nil) -> ScreenshotFile {
    ScreenshotFile(
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        fileName: name,
        width: width,
        height: height,
        hasAlpha: false,
        byteCount: 100,
        fingerprint: fingerprint ?? "sha256:\(name)"
    )
}

func fixtureRefData() throws -> RefData {
    let url = try #require(Bundle.module.url(forResource: "refdata", withExtension: "json", subdirectory: "Fixtures"))
    return try RefData.decode(response: Data(contentsOf: url))
}

func requestLine(_ request: URLRequest) -> String {
    "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
}

func requestData(_ request: URLRequest) throws -> [String: Any] {
    try #require(jsonObject(request.httpBody)["data"] as? [String: Any])
}

func imageResource(id: String, state: String, specID: String? = nil, referenceName: String = "ref", operations: String = "[]") -> String {
    let spec = specID.map { "\"\($0)\"" } ?? "null"
    return #"{"data":{"type":"appAssetLibraryImages","id":"\#(id)","attributes":{"state":"\#(state)","specId":\#(spec),"#
        + #""referenceName":"\#(referenceName)","uploadOperations":\#(operations)}}}"#
}

struct PlacedImage {
    let placement: String
    let image: String
    let reference: String

    init(_ placement: String, _ image: String, _ reference: String) {
        self.placement = placement
        self.image = image
        self.reference = reference
    }
}

func placementList(_ entries: [PlacedImage]) -> String {
    let data = entries.map {
        #"{"type":"appAssetLibraryPlacements","id":"\#($0.placement)","attributes":{"placementType":"APP_SCREENSHOT"},"#
            + #""relationships":{"image":{"data":{"type":"appAssetLibraryImages","id":"\#($0.image)"}}}}"#
    }
    let included = entries.map {
        #"{"type":"appAssetLibraryImages","id":"\#($0.image)","attributes":{"referenceName":"\#($0.reference)"}}"#
    }
    return #"{"data":[\#(data.joined(separator: ","))],"included":[\#(included.joined(separator: ","))]}"#
}

final class LineRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    var lines: [String] {
        storage.withLock { $0 }
    }

    var log: PublishLog {
        PublishLog { [self] line in storage.withLock { $0.append(line) } }
    }
}
