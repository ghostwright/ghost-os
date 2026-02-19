// Actions.swift - All action functions for Ghost OS v2
//
// Maps to MCP tools: ghost_click, ghost_type, ghost_press, ghost_hotkey, ghost_scroll
//
// Uses AXorcist's Element action methods directly.
// Adds: pre-flight checks, AX-native-first strategy, verification, error formatting.

import AppKit
import AXorcist
import Foundation

/// Actions module: operating apps for the agent.
public enum Actions {

    // MARK: - ghost_click

    /// Click an element with pre-flight checks and AX-native-first strategy.
    public static func click(
        query: String?,
        role: String?,
        domId: String?,
        appName: String?,
        x: Double?,
        y: Double?,
        button: String?,
        count: Int?
    ) -> ToolResult {
        let mouseButton: MouseButton = switch button {
        case "right": .right
        case "middle": .middle
        default: .left
        }
        let clickCount = max(1, count ?? 1)

        // Coordinate click (no element lookup needed)
        if let x, let y {
            if let appName {
                _ = FocusManager.focus(appName: appName)
                Thread.sleep(forTimeInterval: 0.2)
            }
            do {
                try Element.clickAt(CGPoint(x: x, y: y), button: mouseButton, clickCount: clickCount)
                Thread.sleep(forTimeInterval: 0.1)
                return ToolResult(
                    success: true,
                    data: ["method": "coordinate", "x": x, "y": y, "button": button ?? "left"]
                )
            } catch {
                return ToolResult(success: false, error: "Click at (\(Int(x)), \(Int(y))) failed: \(error)")
            }
        }

        // Element click - need query or domId
        guard query != nil || domId != nil else {
            return ToolResult(
                success: false,
                error: "Either query/dom_id or x/y coordinates required for ghost_click",
                suggestion: "Use ghost_find to locate elements, or ghost_element_at for coordinates"
            )
        }

        // Find the app and element
        let searchRoot: Element
        if let appName {
            guard let appElement = Perception.appElement(for: appName) else {
                return ToolResult(success: false, error: "Application '\(appName)' not found")
            }
            searchRoot = appElement
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication,
                  let appElement = Element.application(for: frontApp.processIdentifier)
            else {
                return ToolResult(success: false, error: "No frontmost application accessible")
            }
            searchRoot = appElement
        }

        // Find the target element
        let element: Element?
        if let domId {
            element = findByDOMId(domId, in: searchRoot)
        } else if let query {
            var options = ElementSearchOptions()
            options.maxDepth = GhostConstants.semanticDepthBudget
            if let role { options.includeRoles = [role] }
            element = searchRoot.findElement(matching: query, options: options)
        } else {
            element = nil
        }

        guard let element else {
            let target = domId ?? query ?? "unknown"
            return ToolResult(
                success: false,
                error: "Element '\(target)' not found in \(appName ?? "frontmost app")",
                suggestion: "Use ghost_find to see what elements are available"
            )
        }

        // Pre-flight: check actionable
        if !element.isActionable() {
            return ToolResult(
                success: false,
                error: "Element '\(element.computedName() ?? query ?? "")' is not actionable (disabled, hidden, or off-screen)",
                suggestion: "Use ghost_inspect to check the element state"
            )
        }

        // Strategy 1: AX-native press (works from background, no focus needed)
        if mouseButton == .left && clickCount == 1 {
            if let actions = element.supportedActions(), actions.contains("AXPress") {
                let pressed = element.press()
                if pressed {
                    Thread.sleep(forTimeInterval: 0.1)
                    return ToolResult(
                        success: true,
                        data: [
                            "method": "ax-native",
                            "element": element.computedName() ?? query ?? "",
                        ]
                    )
                }
                // AX-native returned false (common in Chrome where performAction
                // is accepted but doesn't actually trigger the click)
                Log.info("AX-native press returned false for '\(element.computedName() ?? "?")' - falling back to synthetic")
            }
        }

        // Strategy 2: Synthetic click (needs focus)
        if let appName {
            _ = FocusManager.focus(appName: appName)
            Thread.sleep(forTimeInterval: 0.2)
        }

        do {
            try element.click(button: mouseButton, clickCount: clickCount)
            Thread.sleep(forTimeInterval: 0.1)
            return ToolResult(
                success: true,
                data: [
                    "method": "synthetic",
                    "element": element.computedName() ?? query ?? "",
                ]
            )
        } catch {
            return ToolResult(
                success: false,
                error: "Click on '\(element.computedName() ?? query ?? "")' failed: \(error)",
                suggestion: "Try ghost_inspect to verify the element, or use x/y coordinates"
            )
        }
    }

    // MARK: - ghost_type

    /// Type text into a field with focus management and verification.
    public static func typeText(
        text: String,
        into: String?,
        domId: String?,
        appName: String?,
        clear: Bool
    ) -> ToolResult {
        // If target field specified (via `into` or `dom_id`), find and type into it
        if into != nil || domId != nil {
            let fieldName = into ?? domId ?? ""

            let searchRoot: Element
            if let appName {
                guard let appElement = Perception.appElement(for: appName) else {
                    return ToolResult(success: false, error: "Application '\(appName)' not found")
                }
                searchRoot = appElement
            } else {
                guard let frontApp = NSWorkspace.shared.frontmostApplication,
                      let appElement = Element.application(for: frontApp.processIdentifier)
                else {
                    return ToolResult(success: false, error: "No frontmost application accessible")
                }
                searchRoot = appElement
            }

            let element: Element?
            if let domId {
                element = findByDOMId(domId, in: searchRoot)
            } else if let into {
                var options = ElementSearchOptions()
                options.maxDepth = GhostConstants.semanticDepthBudget
                element = searchRoot.findElement(matching: into, options: options)
            } else {
                element = nil
            }

            guard let element else {
                return ToolResult(
                    success: false,
                    error: "Field '\(fieldName)' not found",
                    suggestion: "Use ghost_find with role:'AXTextField' to see available text fields"
                )
            }

            // Try AX-native setValue (focus + set value, no need for app focus)
            if element.isAttributeSettable(named: "AXValue") {
                _ = element.setValue(true, forAttribute: "AXFocused")
                Thread.sleep(forTimeInterval: 0.1)

                if clear {
                    _ = element.setValue("", forAttribute: "AXValue")
                    Thread.sleep(forTimeInterval: 0.05)
                }

                let success = element.setValue(text, forAttribute: "AXValue")
                if success {
                    let readback = readbackValue(from: element)
                    return ToolResult(
                        success: true,
                        data: [
                            "method": "ax-native",
                            "field": fieldName,
                            "typed": text,
                            "readback": readback,
                        ]
                    )
                }
            }

            // Fall back to synthetic typing
            if let appName {
                _ = FocusManager.focus(appName: appName)
                Thread.sleep(forTimeInterval: 0.2)
            }

            do {
                try element.typeText(text, delay: 0.005, clearFirst: clear)
                Thread.sleep(forTimeInterval: 0.15)
                let readback = readbackValue(from: element)
                return ToolResult(
                    success: true,
                    data: [
                        "method": "synthetic",
                        "field": fieldName,
                        "typed": text,
                        "readback": readback,
                    ]
                )
            } catch {
                return ToolResult(success: false, error: "Type into '\(fieldName)' failed: \(error)")
            }
        }

        // No target field - type at current focus
        if let appName {
            _ = FocusManager.focus(appName: appName)
            Thread.sleep(forTimeInterval: 0.2)
        }

        do {
            if clear {
                try Element.performHotkey(keys: ["cmd", "a"])
                Thread.sleep(forTimeInterval: 0.05)
                try Element.typeKey(.delete)
                Thread.sleep(forTimeInterval: 0.05)
            }
            try Element.typeText(text, delay: 0.005)
            return ToolResult(success: true, data: ["method": "synthetic-at-focus", "typed": text])
        } catch {
            return ToolResult(success: false, error: "Type failed: \(error)")
        }
    }

    // MARK: - ghost_press

    /// Press a single key with optional modifiers.
    public static func pressKey(
        key: String,
        modifiers: [String]?,
        appName: String?
    ) -> ToolResult {
        if let appName {
            _ = FocusManager.focus(appName: appName)
            Thread.sleep(forTimeInterval: 0.2)
        }

        do {
            if let modifiers, !modifiers.isEmpty {
                // Key with modifiers = hotkey
                let allKeys = modifiers + [key]
                try Element.performHotkey(keys: allKeys)
                FocusManager.clearModifierFlags()
            } else {
                // Single key press
                if let specialKey = mapSpecialKey(key) {
                    try Element.typeKey(specialKey)
                } else if key.count == 1 {
                    try Element.typeText(key)
                } else {
                    return ToolResult(
                        success: false,
                        error: "Unknown key: '\(key)'",
                        suggestion: "Valid keys: return, tab, escape, space, delete, up, down, left, right, f1-f12"
                    )
                }
            }
            return ToolResult(success: true, data: ["key": key, "modifiers": modifiers ?? []])
        } catch {
            return ToolResult(success: false, error: "Key press failed: \(error)")
        }
    }

    // MARK: - ghost_hotkey

    /// Press a key combination with modifier cleanup.
    public static func hotkey(
        keys: [String],
        appName: String?
    ) -> ToolResult {
        guard !keys.isEmpty else {
            return ToolResult(success: false, error: "Keys array cannot be empty")
        }

        if let appName {
            _ = FocusManager.focus(appName: appName)
            Thread.sleep(forTimeInterval: 0.2)
        }

        do {
            try Element.performHotkey(keys: keys)
            // Critical: clear modifier flags to prevent stuck keys
            FocusManager.clearModifierFlags()
            return ToolResult(success: true, data: ["keys": keys])
        } catch {
            FocusManager.clearModifierFlags()
            return ToolResult(success: false, error: "Hotkey \(keys.joined(separator: "+")) failed: \(error)")
        }
    }

    // MARK: - ghost_scroll

    /// Scroll in a direction.
    public static func scroll(
        direction: String,
        amount: Int?,
        appName: String?,
        x: Double?,
        y: Double?
    ) -> ToolResult {
        if let appName {
            _ = FocusManager.focus(appName: appName)
            Thread.sleep(forTimeInterval: 0.2)
        }

        let scrollAmount = Double(amount ?? 3)
        let deltaY: Double
        let deltaX: Double

        switch direction.lowercased() {
        case "up":
            deltaY = scrollAmount * 10
            deltaX = 0
        case "down":
            deltaY = -scrollAmount * 10
            deltaX = 0
        case "left":
            deltaX = scrollAmount * 10
            deltaY = 0
        case "right":
            deltaX = -scrollAmount * 10
            deltaY = 0
        default:
            return ToolResult(
                success: false,
                error: "Invalid direction: '\(direction)'",
                suggestion: "Use: up, down, left, or right"
            )
        }

        do {
            let point: CGPoint? = if let x, let y { CGPoint(x: x, y: y) } else { nil }
            try InputDriver.scroll(deltaX: deltaX, deltaY: deltaY, at: point)
            return ToolResult(success: true, data: ["direction": direction, "amount": amount ?? 3])
        } catch {
            return ToolResult(success: false, error: "Scroll failed: \(error)")
        }
    }

    // MARK: - ghost_window

    /// Window management operations.
    public static func manageWindow(
        action: String,
        appName: String,
        windowTitle: String?,
        x: Double?,
        y: Double?,
        width: Double?,
        height: Double?
    ) -> ToolResult {
        guard let appElement = Perception.appElement(for: appName) else {
            return ToolResult(success: false, error: "Application '\(appName)' not found")
        }

        // List windows
        if action == "list" {
            guard let windows = appElement.windows() else {
                return ToolResult(success: true, data: ["windows": [] as [Any]])
            }
            let infos: [[String: Any]] = windows.compactMap { win in
                var info: [String: Any] = [:]
                if let title = win.title() { info["title"] = title }
                if let pos = win.position() { info["position"] = ["x": Int(pos.x), "y": Int(pos.y)] }
                if let size = win.size() { info["size"] = ["width": Int(size.width), "height": Int(size.height)] }
                if let minimized = win.isMinimized() { info["minimized"] = minimized }
                if let fullscreen = win.isFullScreen() { info["fullscreen"] = fullscreen }
                return info.isEmpty ? nil : info
            }
            return ToolResult(success: true, data: ["windows": infos, "count": infos.count])
        }

        // Find the target window
        let window: Element?
        if let windowTitle {
            window = appElement.windows()?.first {
                $0.title()?.localizedCaseInsensitiveContains(windowTitle) == true
            }
        } else {
            window = appElement.focusedWindow() ?? appElement.mainWindow()
        }

        guard let window else {
            return ToolResult(
                success: false,
                error: "Window not found in '\(appName)'",
                suggestion: "Use ghost_window with action:'list' to see available windows"
            )
        }

        switch action.lowercased() {
        case "minimize":
            _ = window.minimizeWindow()
            return ToolResult(success: true, data: ["action": "minimize", "window": window.title() ?? ""])

        case "maximize":
            _ = window.maximizeWindow()
            return ToolResult(success: true, data: ["action": "maximize", "window": window.title() ?? ""])

        case "close":
            _ = window.closeWindow()
            return ToolResult(success: true, data: ["action": "close", "window": window.title() ?? ""])

        case "restore":
            _ = window.showWindow()
            return ToolResult(success: true, data: ["action": "restore", "window": window.title() ?? ""])

        case "move":
            guard let x, let y else {
                return ToolResult(success: false, error: "move requires x and y parameters")
            }
            _ = window.moveWindow(to: CGPoint(x: x, y: y))
            return ToolResult(success: true, data: ["action": "move", "x": x, "y": y])

        case "resize":
            guard let width, let height else {
                return ToolResult(success: false, error: "resize requires width and height parameters")
            }
            _ = window.resizeWindow(to: CGSize(width: width, height: height))
            return ToolResult(success: true, data: ["action": "resize", "width": width, "height": height])

        default:
            return ToolResult(
                success: false,
                error: "Unknown window action: '\(action)'",
                suggestion: "Valid actions: minimize, maximize, close, restore, move, resize, list"
            )
        }
    }

    // MARK: - Helpers

    /// Find element by DOM id.
    private static func findByDOMId(_ domId: String, in root: Element) -> Element? {
        findByDOMIdWalk(element: root, domId: domId, depth: 0, maxDepth: 50)
    }

    private static func findByDOMIdWalk(element: Element, domId: String, depth: Int, maxDepth: Int) -> Element? {
        guard depth < maxDepth else { return nil }
        if let elDomId = element.rawAttributeValue(named: "AXDOMIdentifier") as? String, elDomId == domId {
            return element
        }
        guard let children = element.children() else { return nil }
        for child in children {
            if let found = findByDOMIdWalk(element: child, domId: domId, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Read back the value of an element after typing. Tries multiple approaches
    /// since Chrome fields often don't return AXValue through the standard API.
    private static func readbackValue(from element: Element) -> String {
        // Try Perception's readValue (handles Chrome AXStaticText bug)
        if let value = Perception.readValue(from: element) {
            return value.count > 200 ? String(value.prefix(200)) + "..." : value
        }

        // Try reading the focused element's value instead (the field we typed into
        // might have wrapped our text in a child element)
        if let parent = element.parent() {
            if let focusedChild = parent.focusedUIElement() {
                if let value = Perception.readValue(from: focusedChild) {
                    return value.count > 200 ? String(value.prefix(200)) + "..." : value
                }
            }
        }

        // Try title as fallback (some fields expose typed text as title)
        if let title = element.title(), !title.isEmpty {
            return title.count > 200 ? String(title.prefix(200)) + "..." : title
        }

        // Try computedName which aggregates multiple sources
        if let name = element.computedName(), !name.isEmpty {
            return name.count > 200 ? String(name.prefix(200)) + "..." : name
        }

        return "(verification unavailable for this field type)"
    }

    /// Map key names to AXorcist SpecialKey enum.
    private static func mapSpecialKey(_ key: String) -> SpecialKey? {
        switch key.lowercased() {
        case "return", "enter": return .return
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "space": return .space
        case "delete", "backspace": return .delete
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "f1": return .f1
        case "f2": return .f2
        case "f3": return .f3
        case "f4": return .f4
        case "f5": return .f5
        case "f6": return .f6
        case "f7": return .f7
        case "f8": return .f8
        case "f9": return .f9
        case "f10": return .f10
        case "f11": return .f11
        case "f12": return .f12
        default: return nil
        }
    }
}
