// FocusManager.swift - Focus orchestration for Ghost OS v2
//
// Handles: ghost_focus, ghost_window, focus save/restore, modifier clearing.
// Uses AXorcist's Element.activateApplication(), focusWindow(), etc.

import AppKit
import AXorcist
import Foundation

/// Manages application and window focus, modifier key cleanup, and focus restoration.
public enum FocusManager {

    /// Focus an app, optionally a specific window. Retries once if first attempt fails.
    public static func focus(appName: String, windowTitle: String? = nil) -> ToolResult {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
        }) else {
            return ToolResult(
                success: false,
                error: "Application '\(appName)' not found",
                suggestion: "Use ghost_state to see all running apps"
            )
        }

        // Try activation with retry
        for attempt in 1...2 {
            let activated = app.activate()
            if !activated && attempt == 2 {
                return ToolResult(
                    success: false,
                    error: "Failed to activate '\(appName)'",
                    suggestion: "The app may be unresponsive. Try ghost_state to check its status."
                )
            }

            // Wait for activation (longer on first attempt)
            Thread.sleep(forTimeInterval: attempt == 1 ? 0.3 : 0.5)

            // If window title specified, find and raise that window
            if let windowTitle {
                if let appElement = Element.application(for: app.processIdentifier),
                   let windows = appElement.windows()
                {
                    if let targetWindow = windows.first(where: {
                        $0.title()?.localizedCaseInsensitiveContains(windowTitle) == true
                    }) {
                        _ = targetWindow.focusWindow()
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
            }

            // Verify focus
            Thread.sleep(forTimeInterval: 0.1)
            let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            if isFront {
                return ToolResult(
                    success: true,
                    data: [
                        "app": app.localizedName ?? appName,
                        "focused": true,
                    ]
                )
            }
            // First attempt failed, retry
        }

        // Both attempts completed but couldn't verify
        return ToolResult(
            success: true,
            data: [
                "app": app.localizedName ?? appName,
                "focused": false,
                "note": "App was activated but focus verification failed. It may still be focused.",
            ]
        )
    }

    /// Save the current frontmost app for later restoration.
    public static func saveFrontmostApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    /// Restore focus to a previously saved app.
    public static func restoreFocus(to app: NSRunningApplication?) {
        app?.activate()
    }

    /// Execute an operation with automatic focus save/restore.
    public static func withFocusRestore<T>(_ operation: () throws -> T) rethrows -> T {
        let savedApp = saveFrontmostApp()
        defer { restoreFocus(to: savedApp) }
        return try operation()
    }

    /// Clear all modifier key flags to prevent stuck keys after hotkeys.
    /// AXorcist's performHotkey can leave Cmd/Shift/Option stuck.
    public static func clearModifierFlags() {
        if let event = CGEvent(source: nil) {
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: 0)
            event.post(tap: .cghidEventTap)
        }
    }
}
