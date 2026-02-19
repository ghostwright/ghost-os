// WaitManager.swift - ghost_wait polling implementation
//
// Polls for conditions (urlContains, elementExists, etc.) with timeout.
// Replaces fixed delays with adaptive waiting.

import AppKit
import AXorcist
import Foundation

/// Polling-based wait for conditions.
public enum WaitManager {

    /// Wait for a condition to be met.
    public static func waitFor(
        condition: String,
        value: String?,
        appName: String?,
        timeout: Double,
        interval: Double
    ) -> ToolResult {
        let deadline = Date().addingTimeInterval(timeout)

        // Capture baseline for "changed" conditions
        let baseline: String?
        switch condition {
        case "urlChanged":
            baseline = getCurrentURL(appName: appName)
        case "titleChanged":
            baseline = getCurrentTitle(appName: appName)
        default:
            baseline = nil
        }

        while Date() < deadline {
            let met = checkCondition(
                condition: condition,
                value: value,
                appName: appName,
                baseline: baseline
            )
            if met {
                return ToolResult(
                    success: true,
                    data: ["condition": condition, "met": true]
                )
            }
            Thread.sleep(forTimeInterval: interval)
        }

        return ToolResult(
            success: false,
            error: "Timed out after \(Int(timeout))s waiting for \(condition)" +
                   (value != nil ? " '\(value!)'" : ""),
            suggestion: "Increase timeout or check if the condition can be met. Use ghost_context to see current state."
        )
    }

    // MARK: - Condition Checks

    private static func checkCondition(
        condition: String,
        value: String?,
        appName: String?,
        baseline: String?
    ) -> Bool {
        switch condition {
        case "urlContains":
            guard let value else { return false }
            guard let url = getCurrentURL(appName: appName) else { return false }
            return url.localizedCaseInsensitiveContains(value)

        case "titleContains":
            guard let value else { return false }
            guard let title = getCurrentTitle(appName: appName) else { return false }
            return title.localizedCaseInsensitiveContains(value)

        case "elementExists":
            guard let value else { return false }
            return findElement(query: value, appName: appName) != nil

        case "elementGone":
            guard let value else { return false }
            return findElement(query: value, appName: appName) == nil

        case "urlChanged":
            let current = getCurrentURL(appName: appName)
            return current != baseline

        case "titleChanged":
            let current = getCurrentTitle(appName: appName)
            return current != baseline

        default:
            return false
        }
    }

    // MARK: - Helpers

    private static func getCurrentURL(appName: String?) -> String? {
        let appElement: Element?
        if let appName {
            appElement = Perception.appElement(for: appName)
        } else if let frontApp = NSWorkspace.shared.frontmostApplication {
            appElement = Element.application(for: frontApp.processIdentifier)
        } else {
            appElement = nil
        }
        guard let appElement, let window = appElement.focusedWindow() else { return nil }
        guard let webArea = Perception.findWebArea(in: window) else { return nil }
        return Perception.readURL(from: webArea)
    }

    private static func getCurrentTitle(appName: String?) -> String? {
        let appElement: Element?
        if let appName {
            appElement = Perception.appElement(for: appName)
        } else if let frontApp = NSWorkspace.shared.frontmostApplication {
            appElement = Element.application(for: frontApp.processIdentifier)
        } else {
            appElement = nil
        }
        guard let appElement else { return nil }
        return appElement.focusedWindow()?.title()
    }

    private static func findElement(query: String, appName: String?) -> Element? {
        let searchRoot: Element?
        if let appName {
            searchRoot = Perception.appElement(for: appName)
        } else if let frontApp = NSWorkspace.shared.frontmostApplication {
            searchRoot = Element.application(for: frontApp.processIdentifier)
        } else {
            searchRoot = nil
        }
        guard let searchRoot else { return nil }
        var options = ElementSearchOptions()
        options.maxDepth = 15
        return searchRoot.findElement(matching: query, options: options)
    }
}
