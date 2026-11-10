import Foundation

public struct PublishLog: Sendable {
    public let verbose: Bool
    private let sink: @Sendable (String) -> Void

    public init(verbose: Bool = false, sink: @escaping @Sendable (String) -> Void = PublishLog.writeToStandardError) {
        self.verbose = verbose
        self.sink = sink
    }

    public static let silent = PublishLog(verbose: false) { _ in }

    public func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        sink(message())
    }

    public func info(_ message: String) {
        sink(message)
    }

    public func warn(_ message: String) {
        sink("warning: \(message)")
    }

    public static let writeToStandardError: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
