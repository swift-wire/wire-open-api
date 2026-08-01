import Foundation

/// Per-request tracing, off unless `WIREOPENAPI_TRACE` is set.
///
/// CI asserts on these lines — a middleware that silently does not run still produces a correct
/// response, so the log is the only evidence it ran. But writing three lines per request is far more
/// expensive than anything being measured, so a benchmark must not pay for it.
enum WireOpenAPITrace {
    nonisolated(unsafe) static let enabled = ProcessInfo.processInfo.environment["WIREOPENAPI_TRACE"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print(message())
    }
}
