// Logger.swift - Structured stderr logging for Ghost OS
//
// ALL output goes to stderr. stdout is reserved exclusively for MCP protocol.
// Never use print() anywhere in the codebase. Use Log.debug/info/warn/error.

import Foundation

/// Log levels ordered by severity.
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }
}

/// Structured logger that always writes to stderr.
public enum Log {
    /// Minimum level to output. Set to .debug for verbose, .info for normal, .warn for quiet.
    public nonisolated(unsafe) static var minimumLevel: LogLevel = .info

    public static func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public static func warn(_ message: @autoclosure () -> String) {
        log(.warn, message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    private static func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.label)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
