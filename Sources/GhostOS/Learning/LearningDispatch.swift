// LearningDispatch.swift - MCP tool handlers for learning mode
//
// Bridges MCPDispatch to LearningRecorder.
// Handles parameter extraction, error formatting, and JSON serialization.

import Foundation

/// MCP tool handlers for ghost_learn_start, ghost_learn_stop, ghost_learn_status.
public enum LearningDispatch {

    // MARK: - ghost_learn_start

    public static func learnStart(args: [String: Any]) -> ToolResult {
        let taskDescription = args["task_description"] as? String
        let recorder = LearningRecorder.shared

        if let error = recorder.start(taskDescription: taskDescription) {
            return ToolResult(
                success: false,
                error: error.localizedDescription,
                suggestion: error.suggestion
            )
        }

        return ToolResult(
            success: true,
            data: [
                "status": "recording",
                "message": "Recording started. The user can now perform the task. Call ghost_learn_stop when done.",
            ]
        )
    }

    // MARK: - ghost_learn_stop

    public static func learnStop(args: [String: Any]) -> ToolResult {
        let recorder = LearningRecorder.shared

        switch recorder.stop() {
        case .failure(let error):
            return ToolResult(
                success: false,
                error: error.localizedDescription,
                suggestion: error.suggestion
            )
        case .success(let (session, actions)):
            let duration = Date().timeIntervalSince(session.startTime)
            let serializedActions = actions.map { serializeAction($0) }

            return ToolResult(
                success: true,
                data: [
                    "task_description": session.taskDescription ?? "",
                    "duration_seconds": Int(duration),
                    "action_count": actions.count,
                    "apps": Array(session.apps),
                    "urls": session.urls,
                    "actions": serializedActions,
                ]
            )
        }
    }

    // MARK: - ghost_learn_status

    public static func learnStatus(args: [String: Any]) -> ToolResult {
        let (recording, count, duration, app) = LearningRecorder.shared.status()
        var data: [String: Any] = [
            "recording": recording,
            "action_count": count,
            "duration_seconds": Int(duration),
        ]
        if let app { data["current_app"] = app }
        return ToolResult(success: true, data: data)
    }

    // MARK: - Serialization

    private static func serializeAction(_ action: ObservedAction) -> [String: Any] {
        var dict: [String: Any] = [
            "timestamp": action.timestamp,
            "app": action.appName,
            "bundle_id": action.appBundleId,
        ]
        dict["window"] = action.windowTitle ?? NSNull()
        dict["url"] = action.url ?? NSNull()
        dict["element"] = action.elementContext.map { serializeElement($0) } ?? NSNull()

        switch action.action {
        case .click(let x, let y, let button, let count):
            dict["action_type"] = "click"
            dict["x"] = x; dict["y"] = y
            dict["button"] = button; dict["count"] = count
        case .typeText(let text):
            dict["action_type"] = "typeText"
            dict["text"] = text
        case .keyPress(let keyCode, let keyName, let modifiers):
            dict["action_type"] = "keyPress"
            dict["key_code"] = keyCode; dict["key_name"] = keyName
            dict["modifiers"] = modifiers
        case .hotkey(let modifiers, let keyName):
            dict["action_type"] = "hotkey"
            dict["modifiers"] = modifiers; dict["key_name"] = keyName
        case .appSwitch(let toApp, let toBundleId):
            dict["action_type"] = "appSwitch"
            dict["to_app"] = toApp; dict["to_bundle_id"] = toBundleId
        case .scroll(let dx, let dy, let x, let y):
            dict["action_type"] = "scroll"
            dict["delta_x"] = dx; dict["delta_y"] = dy
            dict["x"] = x; dict["y"] = y
        case .secureField:
            dict["action_type"] = "secureField"
        }

        return dict
    }

    private static func serializeElement(_ e: ElementContext) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = e.role { dict["role"] = v }
        if let v = e.title { dict["title"] = v }
        if let v = e.identifier { dict["identifier"] = v }
        if let v = e.domId { dict["dom_id"] = v }
        if let v = e.domClasses { dict["dom_classes"] = v }
        if let v = e.computedName { dict["computed_name"] = v }
        if let v = e.parentRole { dict["parent_role"] = v }
        return dict
    }
}
