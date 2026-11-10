import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ScreenshotFile: Sendable, Hashable {
    public let url: URL
    public let fileName: String
    public let width: Int
    public let height: Int
    public let hasAlpha: Bool
    public let byteCount: Int
    public let fingerprint: String
    public let mimeType: String?

    public init(
        url: URL,
        fileName: String,
        width: Int,
        height: Int,
        hasAlpha: Bool,
        byteCount: Int,
        fingerprint: String,
        mimeType: String? = nil
    ) {
        self.url = url
        self.fileName = fileName
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
        self.byteCount = byteCount
        self.fingerprint = fingerprint
        self.mimeType = mimeType
    }

    public var sizeKey: String {
        "\(width)x\(height)"
    }

    public static func read(_ url: URL) throws -> ScreenshotFile {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch {
            throw ASCError.screenshotUnreadable(url.path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ASCError.screenshotUnreadable(url.path)
        }
        return ScreenshotFile(
            url: url,
            fileName: url.lastPathComponent,
            width: width,
            height: height,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            byteCount: bytes.count,
            fingerprint: fingerprint(of: bytes),
            mimeType: CGImageSourceGetType(source).flatMap { UTType($0 as String)?.preferredMIMEType }
        )
    }

    public static func fingerprint(of bytes: Data) -> String {
        "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
