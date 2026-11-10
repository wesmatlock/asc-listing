import Foundation

public enum LocalScreenshots {
    static let extensions: Set<String> = ["png", "jpg", "jpeg"]

    public static func load(_ config: ResolvedScreenshots, localeFilter: Set<String>?) throws -> [String: [ScreenshotFile]] {
        let directory = config.directory
        let sets = SetFolders(directory: directory, sets: config.sets, misconfigured: ASCError.screenshotsMisconfigured)
        guard isDirectory(directory) else {
            throw ASCError.screenshotsMisconfigured("the screenshot directory \(directory.path) does not exist")
        }
        var result: [String: [ScreenshotFile]] = [:]
        var withAlpha: [String] = []
        for source in try sets.sources(localeFilter: localeFilter) {
            let folderURL = directory.appending(path: source.folder, directoryHint: .isDirectory)
            guard isDirectory(folderURL) else {
                throw ASCError.screenshotsMisconfigured("the screenshot folder \(folderURL.path) does not exist")
            }
            let files = try imageURLs(in: folderURL, sets: sets).map(ScreenshotFile.read)
            guard !files.isEmpty else {
                throw ASCError.screenshotsMisconfigured("the screenshot folder \(folderURL.path) has no .png or .jpg files")
            }
            withAlpha += files.filter(\.hasAlpha).map { "\(source.folder)/\($0.fileName)" }
            for locale in source.locales {
                result[locale] = files
            }
        }
        if !withAlpha.isEmpty {
            throw ASCError.screenshotsInvalid(withAlpha)
        }
        return result
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func imageURLs(in folder: URL, sets: SetFolders) throws -> [URL] {
        try sets.contents(of: folder)
            .filter { !isDirectory($0) && extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum LocalCreative {
    public static func load(_ config: ResolvedCreative, localeFilter: Set<String>?) throws -> [String: [CreativeAsset]] {
        let directory = config.directory
        let sets = SetFolders(directory: directory, sets: config.sets, misconfigured: ASCError.creativeMisconfigured)
        guard LocalScreenshots.isDirectory(directory) else {
            throw ASCError.creativeMisconfigured("the creative asset directory \(directory.path) does not exist")
        }
        var read: [URL: ScreenshotFile] = [:]
        var result: [String: [CreativeAsset]] = [:]
        var withAlpha: [String] = []
        for source in try sets.sources(localeFilter: localeFilter) {
            let folderURL = directory.appending(path: source.folder, directoryHint: .isDirectory)
            guard LocalScreenshots.isDirectory(folderURL) else {
                throw ASCError.creativeMisconfigured("the creative asset folder \(folderURL.path) does not exist")
            }
            var assets: [CreativeAsset] = []
            for (placementType, fileName) in config.placements.sorted(by: { $0.key < $1.key }) {
                let url = folderURL.appending(path: fileName)
                guard FileManager.default.fileExists(atPath: url.path), !LocalScreenshots.isDirectory(url) else {
                    throw ASCError.creativeMisconfigured("\(placementType) needs \(url.path), which does not exist")
                }
                let file: ScreenshotFile
                if let known = read[url] {
                    file = known
                } else {
                    file = try ScreenshotFile.read(url)
                    read[url] = file
                    if file.hasAlpha {
                        withAlpha.append("\(source.folder)/\(fileName)")
                    }
                }
                assets.append(CreativeAsset(placementType: placementType, file: file))
            }
            for locale in source.locales {
                result[locale] = assets
            }
        }
        if !withAlpha.isEmpty {
            throw ASCError.screenshotsInvalid(withAlpha)
        }
        return result
    }
}

struct SetFolders {
    let directory: URL
    let sets: ScreenshotSets
    let misconfigured: (String) -> ASCError

    func sources(localeFilter: Set<String>?) throws -> [(folder: String, locales: [String])] {
        let wanted = { (locale: String) in localeFilter?.contains(locale) ?? true }
        return switch sets {
        case let .mapping(mapping):
            try mappedSources(mapping, wanted: wanted)
        case .folders:
            try subfolders(of: directory).filter(wanted).map { ($0, [$0]) }
        }
    }

    func contents(of url: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw misconfigured("cannot list \(url.path): \(error.localizedDescription)")
        }
    }

    private func mappedSources(
        _ mapping: [String: [String]],
        wanted: (String) -> Bool
    ) throws -> [(folder: String, locales: [String])] {
        var owner: [String: String] = [:]
        var sources: [(folder: String, locales: [String])] = []
        for folder in mapping.keys.sorted() {
            let locales = mapping[folder] ?? []
            for locale in locales {
                if let other = owner[locale] {
                    throw misconfigured("locale \(locale) is mapped from both \(other) and \(folder)")
                }
                owner[locale] = folder
            }
            let kept = locales.filter(wanted)
            if !kept.isEmpty {
                sources.append((folder, kept))
            }
        }
        return sources
    }

    private func subfolders(of url: URL) throws -> [String] {
        try contents(of: url).filter(LocalScreenshots.isDirectory).map(\.lastPathComponent).sorted()
    }
}
