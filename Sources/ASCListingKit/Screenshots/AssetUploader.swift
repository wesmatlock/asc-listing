import Foundation

public struct AssetUploader: Sendable {
    private let client: ASCClient
    private let log: PublishLog
    private let sleeper: Sleeper
    private let pollInterval: Duration
    private let timeout: Duration

    public init(
        client: ASCClient,
        log: PublishLog,
        sleeper: Sleeper = .system,
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(900)
    ) {
        self.client = client
        self.log = log
        self.sleeper = sleeper
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public func ensureReady(
        _ file: ScreenshotFile,
        libraryID: String,
        existing: LibraryImage?,
        expectedSpecID: String,
        category: String = AssetRequests.screenshotCategory
    ) async throws -> String {
        if let existing {
            if existing.isReady {
                try Self.checkSpec(existing.specID, of: file, expected: expectedSpecID, required: false)
                return existing.id
            }
            if existing.isReusable {
                return try await waitUntilReady(id: existing.id, file: file, expectedSpecID: expectedSpecID)
            }
            if existing.state == "AWAITING_UPLOAD" {
                try await client.delete("/v1/appAssetLibraryImages/\(existing.id)")
            }
        }
        let bytes = try readBytes(of: file)
        let reserved = try await client.send(
            .post,
            "/v1/appAssetLibraryImages",
            body: AssetRequests.reserveImage(file, libraryID: libraryID, category: category),
            as: Document<Resource<LibraryImageAttributes>>.self
        ).data
        let operations = reserved.attributes?.uploadOperations ?? []
        guard !operations.isEmpty else {
            throw ASCError.invalidUploadOperation("App Store Connect returned no upload operations for \(file.fileName)")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask { try await client.upload(operation, bytes: bytes) }
            }
            try await group.waitForAll()
        }
        _ = try await client.send(
            .patch,
            "/v1/appAssetLibraryImages/\(reserved.id)",
            body: AssetRequests.commitImage(id: reserved.id),
            as: Document<Resource<LibraryImageAttributes>>.self
        )
        let id = try await waitUntilReady(id: reserved.id, file: file, expectedSpecID: expectedSpecID)
        log.info("uploaded \(file.fileName)")
        return id
    }

    private func waitUntilReady(id: String, file: ScreenshotFile, expectedSpecID: String) async throws -> String {
        var waited = Duration.zero
        while true {
            let image = try await client.get(
                "/v1/appAssetLibraryImages/\(id)",
                as: Document<Resource<LibraryImageAttributes>>.self
            ).data.attributes
            let state = LibraryImage(id: id, state: image?.state ?? "UNKNOWN", specID: image?.specId, category: image?.category)
            // App Store Connect can report the ready state a poll or two before it fills in specId.
            if state.isReady, state.specID != nil {
                try Self.checkSpec(state.specID, of: file, expected: expectedSpecID, required: true)
                return id
            }
            if !state.isReusable, state.state != "AWAITING_UPLOAD" {
                if state.state == "FAILED" {
                    try await client.delete("/v1/appAssetLibraryImages/\(id)")
                }
                let details = image?.stateDetails?.summary ?? ""
                throw ASCError.assetFailed(file.fileName, details.isEmpty ? state.state : details)
            }
            guard waited < timeout else { throw ASCError.assetTimeout(file.fileName) }
            try await sleeper.sleep(pollInterval)
            waited += pollInterval
        }
    }

    private func readBytes(of file: ScreenshotFile) throws -> Data {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: file.url)
        } catch {
            throw ASCError.screenshotUnreadable(file.url.path)
        }
        guard ScreenshotFile.fingerprint(of: bytes) == file.fingerprint else {
            throw ASCError.screenshotChanged(file.fileName)
        }
        return bytes
    }

    private static func checkSpec(_ specID: String?, of file: ScreenshotFile, expected: String, required: Bool) throws {
        if specID.map({ $0 != expected }) ?? required {
            throw ASCError.specMismatch(file.fileName, expected, specID)
        }
    }
}
