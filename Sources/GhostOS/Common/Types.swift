// Types.swift - Shared types for Ghost OS v2
//
// Data structures used across modules. Keep these minimal and focused.

import AXorcist
import Foundation

// MARK: - Version

public enum GhostOS {
    public static let version = "2.0.0"
    public static let name = "ghost-os"
}

// MARK: - Tool Result

/// Standard result wrapper returned by all MCP tools.
public struct ToolResult: Sendable {
    public let success: Bool
    public let data: [String: Any]?
    public let error: String?
    public let suggestion: String?
    public let context: ContextInfo?

    public init(
        success: Bool,
        data: [String: Any]? = nil,
        error: String? = nil,
        suggestion: String? = nil,
        context: ContextInfo? = nil
    ) {
        self.success = success
        self.data = data
        self.error = error
        self.suggestion = suggestion
        self.context = context
    }

    /// Convert to MCP-compatible dictionary for JSON serialization.
    public func toDict() -> [String: Any] {
        var result: [String: Any] = ["success": success]
        if let data { result["data"] = data }
        if let error { result["error"] = error }
        if let suggestion { result["suggestion"] = suggestion }
        if let context { result["context"] = context.toDict() }
        return result
    }
}

// MARK: - Context Info

/// Lightweight context snapshot returned with tool results.
public struct ContextInfo: Sendable {
    public let app: String?
    public let window: String?
    public let focusedElement: String?
    public let url: String?

    public init(app: String? = nil, window: String? = nil, focusedElement: String? = nil, url: String? = nil) {
        self.app = app
        self.window = window
        self.focusedElement = focusedElement
        self.url = url
    }

    public func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let app { d["app"] = app }
        if let window { d["window"] = window }
        if let focusedElement { d["focused_element"] = focusedElement }
        if let url { d["url"] = url }
        return d
    }
}

// MARK: - Screenshot Result

/// Result from a screenshot capture.
public struct ScreenshotResult: Sendable {
    public let base64PNG: String
    public let width: Int
    public let height: Int
    public let windowTitle: String?
    public let mimeType: String

    public init(base64PNG: String, width: Int, height: Int, windowTitle: String? = nil, mimeType: String = "image/png") {
        self.base64PNG = base64PNG
        self.width = width
        self.height = height
        self.windowTitle = windowTitle
        self.mimeType = mimeType
    }
}

// MARK: - Ghost Error

/// Errors specific to Ghost OS operations.
public enum GhostError: Error, Sendable {
    case timeout(seconds: TimeInterval)
    case elementNotFound(description: String)
    case actionFailed(description: String)
    case appNotFound(name: String)
    case permissionDenied(String)
    case invalidParameter(String)

    public var localizedDescription: String {
        switch self {
        case let .timeout(seconds):
            "Operation timed out after \(Int(seconds)) seconds"
        case let .elementNotFound(desc):
            "Element not found: \(desc)"
        case let .actionFailed(desc):
            "Action failed: \(desc)"
        case let .appNotFound(name):
            "Application not found: \(name)"
        case let .permissionDenied(msg):
            "Permission denied: \(msg)"
        case let .invalidParameter(msg):
            "Invalid parameter: \(msg)"
        }
    }
}

// MARK: - Constants

public enum GhostConstants {
    public static let semanticDepthBudget = 25
    public static let defaultTimeoutSeconds: TimeInterval = 30
    public static let defaultPollInterval: TimeInterval = 0.5
    public static let maxSearchDepth = 100
    public static let recipesDirectory = "~/.ghost-os/recipes"
    public static let logsDirectory = "~/.ghost-os/logs"
}
