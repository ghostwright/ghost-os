// Perception.swift - All perception functions for Ghost OS v2
//
// Maps to MCP tools: ghost_context, ghost_state, ghost_find, ghost_read,
// ghost_inspect, ghost_element_at, ghost_screenshot
//
// Uses AXorcist's Element, Locator, and command system directly.
// Custom code only for semantic depth tunneling (ghost_read).

import AppKit
import AXorcist
import Foundation

/// Perception module: reading the screen state for the agent.
public enum Perception {

    // MARK: - ghost_context

    /// Get orientation context: focused app, window, URL, focused element, visible interactive elements.
    public static func getContext(appName: String?) -> ToolResult {
        // Find the target app
        let app: NSRunningApplication?
        if let appName {
            app = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }
            guard let app else {
                return ToolResult(
                    success: false,
                    error: "Application '\(appName)' not found or not running",
                    suggestion: "Use ghost_state to see all running apps"
                )
            }
            // Get context for the specified app
            return buildContext(for: app)
        } else {
            // Get context for the frontmost app
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return ToolResult(success: false, error: "No frontmost application found")
            }
            return buildContext(for: frontApp)
        }
    }

    // MARK: - ghost_state

    /// Get all running apps and their windows.
    public static func getState(appName: String?) -> ToolResult {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        if let appName {
            guard let app = apps.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                return ToolResult(
                    success: false,
                    error: "Application '\(appName)' not found",
                    suggestion: "Use ghost_state without app parameter to see all running apps"
                )
            }
            return ToolResult(success: true, data: ["apps": [buildAppInfo(app)]])
        }

        let appInfos = apps.compactMap { buildAppInfo($0) }
        return ToolResult(success: true, data: [
            "app_count": appInfos.count,
            "apps": appInfos,
        ])
    }

    // MARK: - Private helpers

    private static func buildContext(for app: NSRunningApplication) -> ToolResult {
        let pid = app.processIdentifier
        guard let appElement = Element.application(for: pid) else {
            return ToolResult(
                success: true,
                data: [
                    "app": app.localizedName ?? "Unknown",
                    "note": "Could not read accessibility tree. App may need focus for native apps.",
                ],
                suggestion: "Try ghost_focus to bring the app to front first"
            )
        }

        var data: [String: Any] = [
            "app": app.localizedName ?? "Unknown",
            "bundle_id": app.bundleIdentifier ?? "unknown",
            "pid": pid,
        ]

        // Window title
        if let window = appElement.focusedWindow() {
            if let title = window.title() {
                data["window"] = title
            }
            // URL for browsers
            if let webArea = findWebArea(in: window) {
                if let url = readURL(from: webArea) {
                    data["url"] = url
                }
            }
        }

        // Focused element
        if let focused = appElement.focusedUIElement() {
            var focusedInfo: [String: Any] = [:]
            if let role = focused.role() { focusedInfo["role"] = role }
            if let title = focused.title() { focusedInfo["title"] = title }
            if let name = focused.computedName() { focusedInfo["name"] = name }
            focusedInfo["editable"] = focused.isEditable()
            if !focusedInfo.isEmpty {
                data["focused_element"] = focusedInfo
            }
        }

        return ToolResult(
            success: true,
            data: data,
            context: ContextInfo(
                app: app.localizedName,
                window: data["window"] as? String,
                url: data["url"] as? String
            )
        )
    }

    private static func buildAppInfo(_ app: NSRunningApplication) -> [String: Any] {
        var info: [String: Any] = [
            "name": app.localizedName ?? "Unknown",
            "bundle_id": app.bundleIdentifier ?? "unknown",
            "pid": app.processIdentifier,
            "active": app.isActive,
        ]

        if let appElement = Element.application(for: app.processIdentifier) {
            if let windows = appElement.windows() {
                let windowInfos: [[String: Any]] = windows.compactMap { win in
                    var w: [String: Any] = [:]
                    if let title = win.title() { w["title"] = title }
                    if let pos = win.position() { w["position"] = ["x": pos.x, "y": pos.y] }
                    if let size = win.size() { w["size"] = ["width": size.width, "height": size.height] }
                    return w.isEmpty ? nil : w
                }
                if !windowInfos.isEmpty {
                    info["windows"] = windowInfos
                }
            }
        }

        return info
    }

    /// Find AXWebArea element within a window (for reading URLs from browsers).
    private static func findWebArea(in element: Element, depth: Int = 0) -> Element? {
        guard depth < 10 else { return nil }
        if element.role() == "AXWebArea" { return element }
        guard let children = element.children() else { return nil }
        for child in children {
            if let webArea = findWebArea(in: child, depth: depth + 1) {
                return webArea
            }
        }
        return nil
    }

    /// Read URL from an element, working around AXorcist's type conversion.
    private static func readURL(from element: Element) -> String? {
        // Try AXorcist's url() accessor first
        if let url = element.url() {
            return url.absoluteString
        }
        // Fall back to raw API
        if let cfValue = element.rawAttributeValue(named: "AXURL") {
            if let url = cfValue as? URL {
                return url.absoluteString
            }
            if CFGetTypeID(cfValue) == CFURLGetTypeID() {
                return (cfValue as! CFURL as URL).absoluteString
            }
        }
        return nil
    }
}
