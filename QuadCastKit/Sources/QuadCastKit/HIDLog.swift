import Foundation
import os

/// One entry in the in-app log shown by the diagnostics screen.
public struct HIDLogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let level: Level
    public let message: String

    public enum Level: String, Sendable {
        case debug, info, warning, error
    }

    public init(level: Level, message: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.level = level
        self.message = message
    }
}

/// Small logging facade: forwards to `os.Logger` (visible in Console.app) and
/// keeps a bounded in-memory ring buffer for the in-app log view.
///
/// Privacy rules enforced here rather than at call sites:
/// - never log full serial numbers (callers only ever have redacted ones),
/// - raw report hex is logged at `debug` level only, so release builds using
///   `.info` threshold do not emit payload bytes to the system log.
public final class HIDLog: @unchecked Sendable {
    public static let shared = HIDLog()

    private let osLogger = Logger(subsystem: "QuadCastControl", category: "HID")
    private let lock = NSLock()
    private var buffer: [HIDLogEntry] = []
    private let capacity = 500

    public init() {}

    public var entries: [HIDLogEntry] {
        lock.withLock { buffer }
    }

    /// Invoked (on no particular thread) whenever an entry is appended, so the
    /// UI can refresh. Set once from the app.
    public var onAppend: (@Sendable (HIDLogEntry) -> Void)? {
        get { lock.withLock { _onAppend } }
        set { lock.withLock { _onAppend = newValue } }
    }
    private var _onAppend: (@Sendable (HIDLogEntry) -> Void)?

    public func debug(_ message: String) { append(.debug, message) }
    public func info(_ message: String) { append(.info, message) }
    public func warning(_ message: String) { append(.warning, message) }
    public func error(_ message: String) { append(.error, message) }

    /// Logs an outgoing report in hex. Debug-level on purpose — see above.
    public func logSend(_ report: HIDReport, deviceName: String) {
        debug("→ \(deviceName): \(report.hexDescription)")
    }

    private func append(_ level: HIDLogEntry.Level, _ message: String) {
        switch level {
        case .debug: osLogger.debug("\(message, privacy: .public)")
        case .info: osLogger.info("\(message, privacy: .public)")
        case .warning: osLogger.warning("\(message, privacy: .public)")
        case .error: osLogger.error("\(message, privacy: .public)")
        }
        let entry = HIDLogEntry(level: level, message: message)
        let callback = lock.withLock {
            buffer.append(entry)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
            return _onAppend
        }
        callback?(entry)
    }
}
