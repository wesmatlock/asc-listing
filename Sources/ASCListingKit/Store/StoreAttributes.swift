import Foundation

public struct AppAttributes: Codable, Sendable {
    public let name: String?
    public let bundleId: String?
    public let primaryLocale: String?
    public let sku: String?
}

public struct AppStoreVersionAttributes: Codable, Sendable {
    public var platform: String?
    public var versionString: String?
    public var appStoreState: String?
    public var appVersionState: String?
    public var copyright: String?

    public init(
        platform: String? = nil,
        versionString: String? = nil,
        appStoreState: String? = nil,
        appVersionState: String? = nil,
        copyright: String? = nil
    ) {
        self.platform = platform
        self.versionString = versionString
        self.appStoreState = appStoreState
        self.appVersionState = appVersionState
        self.copyright = copyright
    }
}

public struct AppInfoAttributes: Codable, Sendable {
    public let appStoreState: String?
    public let state: String?
}

public struct AppInfoLocalizationAttributes: Codable, Sendable {
    public var locale: String?
    public var name: String?
    public var subtitle: String?
    public var privacyPolicyUrl: String?
    public var privacyChoicesUrl: String?
    public var privacyPolicyText: String?

    public init(locale: String? = nil, fields: [MetadataField: String] = [:]) {
        self.locale = locale
        name = fields[.name]
        subtitle = fields[.subtitle]
        privacyPolicyUrl = fields[.privacyPolicyUrl]
    }

    public var fields: [MetadataField: String] {
        var result: [MetadataField: String] = [:]
        result[.name] = name
        result[.subtitle] = subtitle
        result[.privacyPolicyUrl] = privacyPolicyUrl
        return result
    }
}

public struct VersionLocalizationAttributes: Codable, Sendable {
    public var locale: String?
    public var description: String?
    public var keywords: String?
    public var marketingUrl: String?
    public var promotionalText: String?
    public var supportUrl: String?
    public var whatsNew: String?

    public init(locale: String? = nil, fields: [MetadataField: String] = [:]) {
        self.locale = locale
        description = fields[.description]
        keywords = fields[.keywords]
        marketingUrl = fields[.marketingUrl]
        promotionalText = fields[.promotionalText]
        supportUrl = fields[.supportUrl]
        whatsNew = fields[.whatsNew]
    }

    public var fields: [MetadataField: String] {
        var result: [MetadataField: String] = [:]
        result[.description] = description
        result[.keywords] = keywords
        result[.marketingUrl] = marketingUrl
        result[.promotionalText] = promotionalText
        result[.supportUrl] = supportUrl
        result[.whatsNew] = whatsNew
        return result
    }
}

public enum StoreRequests {
    public static func createVersion(appID: String, platform: Platform, versionString: String) -> RequestBody<AppStoreVersionAttributes> {
        .create(
            type: "appStoreVersions",
            attributes: AppStoreVersionAttributes(platform: platform.rawValue, versionString: versionString),
            relationships: ["app": .one(type: "apps", id: appID)]
        )
    }

    public static func updateVersionCopyright(versionID: String, copyright: String) -> RequestBody<AppStoreVersionAttributes> {
        .update(type: "appStoreVersions", id: versionID, attributes: AppStoreVersionAttributes(copyright: copyright))
    }

    public static func createAppInfoLocalization(
        appInfoID: String,
        locale: String,
        fields: [MetadataField: String]
    ) -> RequestBody<AppInfoLocalizationAttributes> {
        .create(
            type: "appInfoLocalizations",
            attributes: AppInfoLocalizationAttributes(locale: locale, fields: fields),
            relationships: ["appInfo": .one(type: "appInfos", id: appInfoID)]
        )
    }

    public static func updateAppInfoLocalization(id: String, fields: [MetadataField: String]) -> RequestBody<AppInfoLocalizationAttributes> {
        .update(type: "appInfoLocalizations", id: id, attributes: AppInfoLocalizationAttributes(fields: fields))
    }

    public static func createVersionLocalization(
        versionID: String,
        locale: String,
        fields: [MetadataField: String]
    ) -> RequestBody<VersionLocalizationAttributes> {
        .create(
            type: "appStoreVersionLocalizations",
            attributes: VersionLocalizationAttributes(locale: locale, fields: fields),
            relationships: ["appStoreVersion": .one(type: "appStoreVersions", id: versionID)]
        )
    }

    public static func updateVersionLocalization(id: String, fields: [MetadataField: String]) -> RequestBody<VersionLocalizationAttributes> {
        .update(type: "appStoreVersionLocalizations", id: id, attributes: VersionLocalizationAttributes(fields: fields))
    }
}
