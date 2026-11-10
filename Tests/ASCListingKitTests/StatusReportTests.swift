@testable import ASCListingKit
import Testing

struct StatusReportTests {
    private let app = AppRecord(id: "123", name: "MyApp", bundleId: "com.example.MyApp", primaryLocale: "en-US")

    private func report(requested: String?) -> StatusReport {
        StatusReport(
            app: app,
            versions: [VersionSummary(versionString: "1.0", platform: "IOS", state: "PREPARE_FOR_SUBMISSION")],
            requestedVersion: requested,
            appInfoState: "PREPARE_FOR_SUBMISSION",
            locales: [
                StatusReport.LocaleStatus(
                    locale: "en-US",
                    counts: [.name: 10, .subtitle: 22, .description: 1500, .keywords: 98, .promotionalText: 120],
                    screenshots: ["IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": 10],
                    creative: ["PRODUCT_PAGE_HEADER_ASSET": 1, "APP_STORE_SEARCH_RESULTS_ASSET": 1]
                ),
                StatusReport.LocaleStatus(locale: "ja", counts: [.name: 8], screenshots: [:])
            ]
        )
    }

    @Test func `render lists the app, version and info state`() {
        let text = report(requested: "1.0").render()
        #expect(text.contains("MyApp (123)"))
        #expect(text.contains("com.example.MyApp"))
        #expect(text.contains("primary:     en-US"))
        #expect(text.contains("1.0  IOS  PREPARE_FOR_SUBMISSION"))
        #expect(text.contains("app info:    PREPARE_FOR_SUBMISSION"))
    }

    @Test func `render shows counts, dashes, screenshot groups and creative assets per locale`() {
        let lines = report(requested: "1.0").render().split(separator: "\n").map(String.init)
        let header = lines.first { $0.hasPrefix("locale") }
        #expect(header == "locale | name | subtitle | promo | description | keywords | whatsNew | screenshots                             | header | search")
        let english = lines.first { $0.hasPrefix("en-US*") }
        #expect(english == "en-US* | 10   | 22       | 120   | 1500        | 98       | –        | IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE: 10 | 1      | 1")
        let japanese = lines.first { $0.hasPrefix("ja ") }
        #expect(japanese == "ja     | 8    | –        | –     | –           | –        | –        | –                                       | –      | –")
    }

    @Test func `render notes that a version is needed when none was requested`() {
        #expect(report(requested: nil).render().contains("pass --version"))
        #expect(!report(requested: "1.0").render().contains("pass --version"))
    }
}
