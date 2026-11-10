import Foundation

public enum MetadataScope: String, Sendable {
    case appInfo
    case version
}

public enum MetadataField: String, CaseIterable, Sendable {
    case name
    case subtitle
    case privacyPolicyUrl
    case description
    case keywords
    case promotionalText
    case whatsNew
    case supportUrl
    case marketingUrl

    public var fileName: String {
        switch self {
        case .name: "name.txt"
        case .subtitle: "subtitle.txt"
        case .privacyPolicyUrl: "privacy_url.txt"
        case .description: "description.txt"
        case .keywords: "keywords.txt"
        case .promotionalText: "promotional_text.txt"
        case .whatsNew: "release_notes.txt"
        case .supportUrl: "support_url.txt"
        case .marketingUrl: "marketing_url.txt"
        }
    }

    public var limit: Int? {
        switch self {
        case .name, .subtitle: 30
        case .description, .whatsNew: 4000
        case .keywords: 100
        case .promotionalText: 170
        case .privacyPolicyUrl, .supportUrl, .marketingUrl: nil
        }
    }

    public var scope: MetadataScope {
        switch self {
        case .name, .subtitle, .privacyPolicyUrl: .appInfo
        default: .version
        }
    }

    public var displayName: String {
        switch self {
        case .name: "name"
        case .subtitle: "subtitle"
        case .privacyPolicyUrl: "privacy URL"
        case .description: "description"
        case .keywords: "keywords"
        case .promotionalText: "promotional text"
        case .whatsNew: "release notes"
        case .supportUrl: "support URL"
        case .marketingUrl: "marketing URL"
        }
    }
}
