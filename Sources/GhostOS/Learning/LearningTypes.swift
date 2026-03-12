// LearningTypes.swift - Data types for the self-learning system
//
// These types are the OUTPUT of recording. They are NOT recipes.
// The agent (Claude Code) converts these into Recipe JSON via ghost_recipe_save.

import Foundation

// MARK: - Learning Error

/// Errors specific to learning mode operations.
public enum LearningError: Error, Sendable {
    case inputMonitoringNotGranted
    case alreadyRecording
    case notRecording
    case tapCreationFailed
    case noActionsRecorded

    public var localizedDescription: String {
        switch self {
        case .inputMonitoringNotGranted:
            "Input Monitoring permission not granted"
        case .alreadyRecording:
            "Learning is already in progress. Call ghost_learn_stop first."
        case .notRecording:
            "No learning session is active. Call ghost_learn_start first."
        case .tapCreationFailed:
            "Failed to create CGEvent tap. Input Monitoring permission may be stale."
        case .noActionsRecorded:
            "No actions were recorded during the learning session."
        }
    }

    public var suggestion: String {
        switch self {
        case .inputMonitoringNotGranted:
            "System Settings > Privacy & Security > Input Monitoring. Add your terminal app. Then restart the MCP server."
        case .alreadyRecording:
            "Call ghost_learn_stop to end the current session, or ghost_learn_status to check."
        case .notRecording:
            "Call ghost_learn_start to begin recording."
        case .tapCreationFailed:
            "Remove and re-add your terminal app in System Settings > Privacy & Security > Input Monitoring."
        case .noActionsRecorded:
            "Make sure you performed actions (clicks, typing) while recording was active."
        }
    }
}

// MARK: - Observed Action

/// A single observed user action during learning mode.
/// Produced by the CGEvent tap + AX enrichment pipeline.
public struct ObservedAction: Sendable {
    public let timestamp: UInt64
    public let action: ObservedActionType
    public let appName: String
    public let appBundleId: String
    public let windowTitle: String?
    public let url: String?
    public let elementContext: ElementContext?
}

/// The type of observed action.
public enum ObservedActionType: Sendable {
    case click(x: Double, y: Double, button: String, count: Int)
    case typeText(text: String)
    case keyPress(keyCode: Int, keyName: String, modifiers: [String])
    case hotkey(modifiers: [String], keyName: String)
    case appSwitch(toApp: String, toBundleId: String)
    case scroll(deltaX: Int, deltaY: Int, x: Double, y: Double)
    case secureField
}

/// AX context for the element that was acted upon (e.g., clicked).
public struct ElementContext: Sendable {
    public let role: String?
    public let title: String?
    public let identifier: String?
    public let domId: String?
    public let domClasses: String?
    public let computedName: String?
    public let parentRole: String?
}

// MARK: - Learning Session

/// State of an active learning session. Held by LearningRecorder.
public struct LearningSession: Sendable {
    public let taskDescription: String?
    public let startTime: Date
    public var actions: [ObservedAction]
    public var apps: Set<String>
    public var urls: [String]

    public nonisolated init(taskDescription: String?) {
        self.taskDescription = taskDescription
        self.startTime = Date()
        self.actions = []
        self.apps = []
        self.urls = []
    }
}

// MARK: - Learning Log

/// Thread-safe stderr logging for the learning subsystem.
/// Exists because Log (Logger.swift) inherits MainActor from the package-level
/// default isolation and cannot be called from the nonisolated learning thread.
/// Matches Log's output format for consistency in stderr.
nonisolated func learningLog(_ level: String, _ message: String) {
    // Per-call allocation is intentional: ISO8601DateFormatter is not thread-safe,
    // and this function is called from both the main thread and the learning thread.
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [\(level)] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// MARK: - Learning Constants

nonisolated public enum LearningConstants {
    /// Keystroke coalescing: flush after this many seconds of inactivity.
    public static let keystrokeFlushTimeoutSeconds: Double = 0.5
    /// Scroll coalescing: flush after this many seconds of inactivity.
    public static let scrollFlushTimeoutSeconds: Double = 0.3
    /// Maximum recording duration (safety limit): 10 minutes.
    public static let maxRecordingDurationSeconds: Double = 600
    /// Restricted bundle IDs: pause recording in these apps.
    public static let restrictedBundleIds: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
    ]
    /// Sensitive field name patterns (case-insensitive).
    public static let sensitiveFieldPatterns: [String] = [
        "password", "passwd", "secret", "token", "api_key", "api.key",
        "apikey", "credential", "private.key", "ssn", "social.security",
    ]
}
