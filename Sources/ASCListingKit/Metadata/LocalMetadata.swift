import Foundation

public struct LocalMetadata: Sendable, Equatable {
    public var locales: [String: [MetadataField: String]]
    public var copyright: String?

    public init(locales: [String: [MetadataField: String]] = [:], copyright: String? = nil) {
        self.locales = locales
        self.copyright = copyright
    }

    public static let copyrightFileName = "copyright.txt"

    public static func load(directory: URL) throws -> (LocalMetadata, warnings: [String]) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ASCError.metadataInvalid(["the metadata directory \(directory.path) does not exist"])
        }
        var result = LocalMetadata()
        var warnings: [String] = []
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            let name = entry.lastPathComponent
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                let (fields, localeWarnings) = try loadLocale(entry)
                result.locales[name] = fields
                warnings += localeWarnings
            } else if name == copyrightFileName {
                result.copyright = try read(entry)
                if result.copyright == nil {
                    warnings.append(emptyWarning(name))
                }
            } else {
                warnings.append("ignoring \(name) in the metadata directory")
            }
        }
        let violations = result.violations()
        if !violations.isEmpty {
            throw ASCError.metadataInvalid(violations)
        }
        return (result, warnings)
    }

    public func violations() -> [String] {
        var found: [String] = []
        for locale in locales.keys.sorted() {
            for field in MetadataField.allCases {
                guard let limit = field.limit, let value = locales[locale]?[field], value.count > limit else { continue }
                found.append("\(locale) \(field.rawValue): \(value.count) > \(limit)")
            }
        }
        return found
    }

    private static func loadLocale(_ directory: URL) throws -> ([MetadataField: String], [String]) {
        var fields: [MetadataField: String] = [:]
        var warnings: [String] = []
        let locale = directory.lastPathComponent
        let known = Dictionary(uniqueKeysWithValues: MetadataField.allCases.map { ($0.fileName, $0) })
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            if let field = known[file.lastPathComponent] {
                if let text = try read(file) {
                    fields[field] = text
                } else {
                    warnings.append(emptyWarning("\(locale)/\(file.lastPathComponent)"))
                }
            } else if file.pathExtension == "txt" {
                warnings.append("ignoring unknown file \(locale)/\(file.lastPathComponent)")
            }
        }
        return (fields, warnings)
    }

    private static func emptyWarning(_ path: String) -> String {
        "ignoring empty file \(path); the field is left as it is on App Store Connect"
    }

    private static func read(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        guard var text = String(data: data, encoding: .utf8) else {
            throw ASCError.metadataInvalid(["\(url.lastPathComponent) is not valid UTF-8"])
        }
        if text.hasSuffix("\r\n") {
            text.removeLast()
        } else if text.hasSuffix("\n") {
            text.removeLast()
        }
        return text.isEmpty ? nil : text
    }
}
