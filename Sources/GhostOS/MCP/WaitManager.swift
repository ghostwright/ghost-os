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
            return elementExistsByName(query: value, appName: appName)

        case "elementGone":
            guard let value else { return false }
            return !elementExistsByName(query: value, appName: appName)

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
        guard let appElement = resolveApp(appName: appName) else { return nil }
        guard let window = appElement.focusedWindow() else { return nil }
        guard let webArea = Perception.findWebArea(in: window) else { return nil }
        return Perception.readURL(from: webArea)
    }

    private static func getCurrentTitle(appName: String?) -> String? {
        guard let appElement = resolveApp(appName: appName) else { return nil }
        return appElement.focusedWindow()?.title()
    }

    /// Check if a UI element with the given name/label exists.
    /// Uses computedName matching to avoid false positives from text content.
    /// AXorcist's findElement(matching:) matches against stringValue which
    /// causes false positives when the search term appears in terminal scrollback
    /// or page content.
    private static func elementExistsByName(query: String, appName: String?) -> Bool {
        guard let appElement = resolveApp(appName: appName) else { return false }

        // Walk the tree looking for elements whose computedName matches
        return findByComputedName(
            query: query.lowercased(),
            in: appElement,
            depth: 0,
            maxDepth: 15
        )
    }

    /// Search for an element by computedName (not stringValue/text content).
    private static func findByComputedName(
        query: String,
        in element: Element,
        depth: Int,
        maxDepth: Int
    ) -> Bool {
        guard depth < maxDepth else { return false }

        // Check name-related properties. Also check AXValue via raw API
        // for Chrome AXStaticText elements that only have text in AXValue.
        let checkProps: [String?] = [
            element.title(),
            element.computedName(),
            element.descriptionText(),
            element.identifier(),
            Perception.readValue(from: element),
        ]
        for prop in checkProps {
            if let text = prop?.lowercased(), text.contains(query) {
                return true
            }
        }

        // Recurse into children
        guard let children = element.children() else { return false }
        for child in children {
            if findByComputedName(query: query, in: child, depth: depth + 1, maxDepth: maxDepth) {
                return true
            }
        }
        return false
    }

    private static func resolveApp(appName: String?) -> Element? {
        if let appName {
            return Perception.appElement(for: appName)
        } else if let frontApp = NSWorkspace.shared.frontmostApplication {
            return Element.application(for: frontApp.processIdentifier)
        }
        return nil
    }
}
