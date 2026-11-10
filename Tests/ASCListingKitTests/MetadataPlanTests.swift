@testable import ASCListingKit
import Testing

struct MetadataPlanTests {
    private func record(_ locale: String, _ fields: [MetadataField: String]) -> LocalizationRecord {
        LocalizationRecord(id: "id-\(locale)", locale: locale, fields: fields)
    }

    private func plan(
        local: LocalMetadata,
        info: [LocalizationRecord] = [],
        version: [LocalizationRecord] = [],
        copyright: String? = nil,
        filter: Set<String>? = nil
    ) -> MetadataPlan {
        MetadataPlan.make(
            local: local,
            appInfoLocalizations: info,
            versionLocalizations: version,
            remoteCopyright: copyright,
            localeFilter: filter
        )
    }

    @Test func `missing locales are created per scope`() {
        let local = LocalMetadata(locales: ["es": [.name: "N", .keywords: "k"]])
        let result = plan(local: local, version: [record("es", [:])])
        #expect(result.locales.count == 1)
        #expect(result.locales[0].appInfo == .create([.name: "N"]))
        #expect(result.locales[0].version == .update([FieldChange(field: .keywords, old: nil, new: "k")]))
        let versionOnly = plan(local: local, info: [record("es", [:])])
        #expect(versionOnly.locales[0].appInfo == .update([FieldChange(field: .name, old: nil, new: "N")]))
        #expect(versionOnly.locales[0].version == .create([.keywords: "k"]))
    }

    @Test func `update lists only changed fields with old and new`() {
        let local = LocalMetadata(locales: ["en-US": [.name: "Same", .subtitle: "New subtitle", .keywords: "a,b"]])
        let result = plan(
            local: local,
            info: [record("en-US", [.name: "Same", .subtitle: "Old"])],
            version: [record("en-US", [.keywords: "a,b", .description: "remote only"])]
        )
        #expect(result.locales[0].appInfo == .update([FieldChange(field: .subtitle, old: "Old", new: "New subtitle")]))
        #expect(result.locales[0].version == .unchanged)
        #expect(result.hasChanges)
    }

    @Test func `identical data is all unchanged`() {
        let local = LocalMetadata(locales: ["en-US": [.name: "N", .keywords: "k"]], copyright: "c")
        let result = plan(
            local: local,
            info: [record("en-US", [.name: "N"])],
            version: [record("en-US", [.keywords: "k"])],
            copyright: "c"
        )
        #expect(result.locales[0].appInfo == .unchanged)
        #expect(result.locales[0].version == .unchanged)
        #expect(result.copyright == nil)
        #expect(!result.hasChanges)
    }

    @Test func `remote only locales and scopes without local fields are untouched`() {
        let local = LocalMetadata(locales: ["en-US": [.keywords: "k"]])
        let result = plan(local: local, info: [record("de", [.name: "x"])], version: [record("de", [:]), record("en-US", [.keywords: "k"])])
        #expect(result.locales.map(\.locale) == ["de", "en-US"])
        #expect(result.locales[0].appInfo == .untouched)
        #expect(result.locales[0].version == .untouched)
        #expect(result.locales[1].appInfo == .untouched)
        #expect(result.locales[1].version == .unchanged)
    }

    @Test func `the locale filter limits the plan`() {
        let local = LocalMetadata(locales: ["en-US": [.name: "a"], "es": [.name: "b"], "fr": [.name: "c"]])
        let result = plan(local: local, filter: ["es", "fr", "zz"])
        #expect(result.locales.map(\.locale) == ["es", "fr"])
    }

    @Test func `a locale filter leaves the version wide copyright out and names unmatched locales`() {
        let local = LocalMetadata(locales: ["en-US": [.name: "N"]], copyright: "2026 Me")
        let filtered = plan(local: local, info: [record("ja", [:])], copyright: "2025 Me", filter: ["en-US", "ja", "xx"])
        #expect(filtered.copyright == nil)
        #expect(filtered.unmatchedLocales(["en-US", "ja", "xx"]) == ["xx"])
        #expect(filtered.unmatchedLocales(nil).isEmpty)
    }

    @Test func `copyright changes only when a local value differs`() {
        let local = LocalMetadata(locales: [:], copyright: "2026 Me")
        #expect(plan(local: local, copyright: nil).copyright == CopyrightChange(old: nil, new: "2026 Me"))
        #expect(plan(local: local, copyright: "2025 Me").copyright == CopyrightChange(old: "2025 Me", new: "2026 Me"))
        #expect(plan(local: local, copyright: "2026 Me").copyright == nil)
        #expect(plan(local: LocalMetadata(), copyright: "x").copyright == nil)
    }

    @Test func `render marks the primary locale and counts actions`() {
        let local = LocalMetadata(locales: [
            "en-US": [.name: "Table", .subtitle: "Learn", .keywords: "k"],
            "es": [.name: "Mesa"]
        ])
        let result = plan(
            local: local,
            info: [record("en-US", [.name: "Tablex"])],
            version: [record("en-US", [.keywords: "k"])]
        )
        let text = result.render(primaryLocale: "en-US")
        #expect(text.contains("en-US*"))
        #expect(text.contains("update name 6→5, subtitle ∅→5"))
        #expect(text.contains("create (name)"))
        #expect(text.contains("1 to create, 1 to update, 1 unchanged"))
        #expect(!text.contains("warning"))
        #expect(result.render(primaryLocale: "ja").contains("warning: no local data targets the primary locale ja"))
    }
}
