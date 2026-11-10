import Foundation

public struct APIErrorItem: Codable, Sendable, Equatable {
    public let status: String?
    public let code: String?
    public let title: String?
    public let detail: String?

    public init(status: String? = nil, code: String? = nil, title: String? = nil, detail: String? = nil) {
        self.status = status
        self.code = code
        self.title = title
        self.detail = detail
    }

    public var message: String {
        let head = [status, code].compactMap(\.self).joined(separator: " ")
        let body = detail ?? title ?? ""
        if head.isEmpty {
            return body
        }
        return body.isEmpty ? head : "\(head): \(body)"
    }
}

public enum ASCError: Error, CustomStringConvertible, Sendable {
    case missingCredentials
    case invalidCredentials(String)
    case api(status: Int, errors: [APIErrorItem])
    case transport(String)
    case decoding(String)
    case invalidURL(String)
    case invalidUploadOperation(String)
    case uploadFailed(status: Int, response: String?)
    case appNotFound(String)
    case versionNotFound(String, available: [String])
    case notEditable(String, state: String)
    case metadataInvalid([String])
    case step(String, any Error)
    case screenshotsMisconfigured(String)
    case screenshotUnreadable(String)
    case screenshotsInvalid([String])
    case screenshotChanged(String)
    case unsupportedScreenshotSize(String)
    case ambiguousPlacement(String, [String])
    case tooManyScreenshots(String, String, Int, Int)
    case assetFailed(String, String?)
    case assetTimeout(String)
    case specMismatch(String, String, String?)
    case orderMismatch(String, String)
    case versionRequired
    case notConfigured(String)
    case screenshotGroupsFailed([String])
    case internalInconsistency(String)
    case creativeMisconfigured(String)
    case unknownPlacementType(String, category: String, known: [String])
    case unsupportedAssetSize(String, placementType: String, accepted: [String])
    case unsupportedImageFormat(String, mimeType: String, size: String, spec: String, accepted: [String])
    case placementNotVisible(String, String)
    case creativePlacementsFailed([String])

    public var description: String {
        switch self {
        case .missingCredentials:
            "No App Store Connect credentials found. Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_P8_PATH, "
                + "or create ~/.appstoreconnect/config.json with keyId, issuerId and p8Path."
        case let .invalidCredentials(reason):
            "Invalid App Store Connect credentials: \(reason)."
        case let .api(status, errors):
            Self.apiMessage(status: status, errors: errors)
        case let .transport(reason):
            "Network error: \(reason)"
        case let .decoding(reason):
            "Unexpected App Store Connect response: \(reason)"
        case let .invalidURL(value):
            "Invalid URL: \(value)"
        case let .invalidUploadOperation(reason):
            "Invalid upload operation: \(reason)"
        case let .uploadFailed(status, response):
            "Asset upload failed with HTTP status \(status)" + (response.map { ": \($0)" } ?? ".")
        case let .appNotFound(bundleId):
            "No app with bundle id \(bundleId) exists in this App Store Connect account."
        case let .versionNotFound(version, available):
            "No version \(version) exists. Available versions: "
                + (available.isEmpty ? "none" : available.joined(separator: ", "))
                + ". Pass --create-version to create it."
        case let .notEditable(what, state):
            "The \(what) is in state \(state) and cannot be edited."
        case let .metadataInvalid(violations):
            "The metadata is invalid:\n" + violations.map { "  \($0)" }.joined(separator: "\n")
        case let .step(label, underlying):
            "\(label): \(underlying)"
        case let .screenshotsMisconfigured(reason):
            "Screenshots: \(reason)"
        case let .screenshotUnreadable(path):
            "Cannot read the image size of \(path)."
        case let .screenshotsInvalid(files):
            "App Store Connect rejects images with an alpha channel. Flatten these files:\n"
                + files.map { "  \($0)" }.joined(separator: "\n")
        case let .screenshotChanged(fileName):
            "\(fileName) changed after the plan was made. Run the command again."
        case let .unsupportedScreenshotSize(size):
            "No App Store screenshot slot accepts \(size) images."
        case let .ambiguousPlacement(size, candidates):
            "\(size) images fit several placement groups (\(candidates.joined(separator: ", "))). "
                + "Pick one under screenshots.placementGroups in the manifest."
        case let .tooManyScreenshots(locale, group, count, max):
            "\(locale) \(group) has \(count) screenshots; App Store Connect allows \(max)."
        case let .assetFailed(fileName, details):
            "App Store Connect could not process \(fileName)" + (details.map { ": \($0)" } ?? ".")
        case let .assetTimeout(fileName):
            "\(fileName) was still processing when the wait ran out."
        case let .specMismatch(fileName, expected, got):
            "\(fileName) was processed as image spec \(got ?? "none"), expected \(expected)."
        case .versionRequired:
            "No version given. Pass --version or set \"version\" in the manifest."
        case let .notConfigured(block):
            "The manifest has no \"\(block)\" section."
        case let .orderMismatch(locale, group):
            "\(locale) \(group): the screenshots on App Store Connect are not in the requested order after placing them."
        case let .screenshotGroupsFailed(groups):
            "\(groups.count) screenshot \(groups.count == 1 ? "group" : "groups") failed:\n"
                + groups.map { "  \($0)" }.joined(separator: "\n")
                + "\nThe other groups went through. To finish, re-run the same command: it re-plans from what is live and only redoes these."
        case let .internalInconsistency(reason):
            "asc-listing reached an inconsistent state (a bug in this tool, not an App Store Connect problem): \(reason)."
        case let .creativeMisconfigured(reason):
            "Creative assets: \(reason)"
        case let .unknownPlacementType(type, category, known):
            "App Store Connect has no \(category) placement type \(type). Use one of: "
                + (known.isEmpty ? "none" : known.joined(separator: ", ")) + "."
        case let .unsupportedAssetSize(size, type, accepted):
            "\(type) does not accept \(size) images. Accepted sizes: "
                + (accepted.isEmpty ? "none" : accepted.joined(separator: ", ")) + "."
        case let .unsupportedImageFormat(fileName, mimeType, size, spec, accepted):
            "\(fileName) is \(mimeType), but App Store Connect accepts only \(accepted.joined(separator: " or ")) "
                + "at \(size) (spec \(spec)). Export it in an accepted format."
        case let .placementNotVisible(locale, slot):
            "\(locale) \(slot): the placed image does not show on App Store Connect after placing it."
        case let .creativePlacementsFailed(placements):
            "\(placements.count) creative \(placements.count == 1 ? "placement" : "placements") failed:\n"
                + placements.map { "  \($0)" }.joined(separator: "\n")
                + "\nThe others went through. To finish, re-run the same command: it re-plans from what is live and only redoes these."
        }
    }

    private static func apiMessage(status: Int, errors: [APIErrorItem]) -> String {
        var lines = errors.map(\.message).filter { !$0.isEmpty }
        if lines.isEmpty {
            lines = ["HTTP \(status)"]
        }
        if status == 401 {
            lines.append("Hint: check the key id, issuer id and that the key isn't revoked; also check the Mac's clock.")
        }
        if status == 403 {
            lines.append("Hint: the API key needs the App Manager or Admin role.")
        }
        return lines.joined(separator: "\n")
    }
}
