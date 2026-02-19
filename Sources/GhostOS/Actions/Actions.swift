// Actions.swift - All action functions for Ghost OS v2
//
// Maps to MCP tools: ghost_click, ghost_type, ghost_press, ghost_hotkey,
// ghost_scroll, ghost_window
//
// Architecture: Uses AXorcist's COMMAND SYSTEM (runCommand with Locators)
// for AX-native operations, with synthetic fallback for Chrome/web apps.
//
// The Action Loop (every action follows this):
// 1. PRE-FLIGHT: find element via AXorcist, check actionable
// 2. EXECUTE: AX-native first, synthetic fallback if no state change
// 3. POST-VERIFY: brief pause, read post-action context
// 4. CLEANUP: clear modifier flags, restore focus

import AppKit
import AXorcist
import Foundation

/// Actions module: operating apps for the agent.
public enum Actions {

    // MARK: - ghost_click

    /// Click an element. AX-native first via AXorcist's PerformAction command,
    /// synthetic fallback with position-based click.
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

        // Coordinate-based click (no element lookup)
        if let x, let y {
            if let appName {
                _ = FocusManager.focus(appName: appName)
                Thread.sleep(forTimeInterval: 0.2)
            }
            do {
                try InputDriver.click(at: CGPoint(x: x, y: y), button: mouseButton, count: clickCount)
                Thread.sleep(forTimeInterval: 0.15)
                return ToolResult(
                    success: true,
                    data: ["method": "coordinate", "x": x, "y": y]
                )
            } catch {
                return ToolResult(success: false, error: "Click at (\(Int(x)), \(Int(y))) failed: \(error)")
            }
        }

        // Element-based click needs query or domId
        guard query != nil || domId != nil else {
            return ToolResult(
                success: false,
                error: "Either query/dom_id or x/y coordinates required",
                suggestion: "Use ghost_find to locate elements, or ghost_element_at for coordinates"
            )
        }

        // Build locator for AXorcist
        let locator = LocatorBuilder.build(query: query, role: role, domId: domId)

        // Strategy 1: AX-native via AXorcist's PerformAction command
        // This handles element finding, action validation, and execution internally
        if mouseButton == .left && clickCount == 1 {
            let actionCmd = PerformActionCommand(
                appIdentifier: appName,
                locator: locator,
                action: "AXPress",
                maxDepthForSearch: GhostConstants.semanticDepthBudget
            )
            let response = AXorcist.shared.runCommand(
                AXCommandEnvelope(commandID: "click", command: .performAction(actionCmd))
            )

            switch response {
            case .success:
                Thread.sleep(forTimeInterval: 0.15)
                Log.info("AX-native press succeeded for '\(query ?? domId ?? "")'")
                return ToolResult(
                    success: true,
                    data: [
                        "method": "ax-native",
                        "element": query ?? domId ?? "",
                    ]
                )
            case let .error(message, code, _):
                // Log the actual error so we know WHY AX-native failed
                Log.info("AX-native press failed for '\(query ?? domId ?? "")': [\(code)] \(message) - trying synthetic")
            }
        }

        // Strategy 2: Find element position, synthetic click
        // Need to find the element ourselves to get its position
        guard let element = findElement(locator: locator, appName: appName) else {
            return ToolResult(
                success: false,
                error: "Element '\(query ?? domId ?? "")' not found in \(appName ?? "frontmost app")",
                suggestion: "Use ghost_find to see what elements are available"
            )
        }

        // Pre-flight: check actionable
        if !element.isActionable() {
            return ToolResult(
                success: false,
                error: "Element '\(element.computedName() ?? query ?? "")' is not actionable",
                suggestion: "Element may be disabled, hidden, or off-screen. Use ghost_inspect to check."
            )
        }

        // Focus the app for synthetic input
        if let appName {
            _ = FocusManager.focus(appName: appName)
            Thread.sleep(forTimeInterval: 0.2)
        }

        do {
            try element.click(button: mouseButton, clickCount: clickCount)
            Thread.sleep(forTimeInterval: 0.15)
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
                error: "Click failed: \(error)",
                suggestion: "Try ghost_inspect on the element, or use x/y coordinates"
            )
        }
    }

    // MARK: - ghost_type

    /// Type text into a field. Uses AXorcist's SetFocusedValue command for
    /// AX-native typing (focus + setValue), with synthetic typeText fallback.
    public static func typeText(
        text: String,
        into: String?,
        domId: String?,
        appName: String?,
        clear: Bool
    ) -> ToolResult {
        // If target field specified, find it and type into it
        if let fieldName = into ?? domId {
            // For 'into' parameter, use field-specific search that prefers
            // editable/interactive roles (AXComboBox, AXTextField, AXTextArea)
            // over random elements that happen to contain the text.
            // This prevents into:"To" from matching "Skip to content" instead
            // of the actual "To recipients" field.
            let element: Element?
            if let domId {
                let locator = LocatorBuilder.build(domId: domId)
                element = findElement(locator: locator, appName: appName)
            } else if let into {
                element = findEditableField(named: into, appName: appName)
            } else {
                element = nil
            }

            guard let element else {
                return ToolResult(
                    success: false,
                    error: "Field '\(fieldName)' not found",
                    suggestion: "Use ghost_find to see available fields, or ghost_context for orientation"
                )
            }

            // Strategy 1: AX-native setValue
            // Try setting value directly via AX API (works for native fields)
            if element.isAttributeSettable(named: "AXValue") {
                // Focus the element first
                _ = element.setValue(true, forAttribute: "AXFocused")
                Thread.sleep(forTimeInterval: 0.1)

                if clear {
                    _ = element.setValue("", forAttribute: "AXValue")
                    Thread.sleep(forTimeInterval: 0.05)
                }

                let setOk = element.setValue(text, forAttribute: "AXValue")
                if setOk {
                    Thread.sleep(forTimeInterval: 0.15)

                    // Verify: read back AXValue to confirm it stuck
                    let readback = readbackFromElement(element)
                    let textPrefix = String(text.prefix(20))
                    if readback.contains(textPrefix) {
                        // setValue worked and verified
                        return ToolResult(
                            success: true,
                            data: [
                                "method": "ax-native-setValue",
                                "field": fieldName,
                                "typed": text,
                                "readback": readback,
                            ]
                        )
                    }
                    // setValue returned true but text didn't stick (Chrome web fields)
                    Log.info("setValue for '\(fieldName)' returned OK but readback doesn't match - falling back to click-then-type")
                }
            }

            // Strategy 2: Click the element to focus it, then type synthetically
            // This is what v1's ActionExecutor did and it works for Chrome/Gmail
            if let appName {
                _ = FocusManager.focus(appName: appName)
                Thread.sleep(forTimeInterval: 0.2)
            }

            // Click the element to put cursor in the field
            if element.isActionable() {
                do {
                    try element.click()
                    Thread.sleep(forTimeInterval: 0.15)
                } catch {
                    // Click failed, try AX focus as fallback
                    _ = element.setValue(true, forAttribute: "AXFocused")
                    Thread.sleep(forTimeInterval: 0.1)
                }
            } else {
                _ = element.setValue(true, forAttribute: "AXFocused")
                Thread.sleep(forTimeInterval: 0.1)
            }

            do {
                if clear {
                    try Element.performHotkey(keys: ["cmd", "a"])
                    Thread.sleep(forTimeInterval: 0.05)
                    try Element.typeKey(.delete)
                    Thread.sleep(forTimeInterval: 0.05)
                    FocusManager.clearModifierFlags()
                }
                try Element.typeText(text, delay: 0.01)
                Thread.sleep(forTimeInterval: 0.15)

                // Read back from the same element we found earlier
                let readback = readbackFromElement(element)
                return ToolResult(
                    success: true,
                    data: [
                        "method": "click-then-type",
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
                FocusManager.clearModifierFlags()
            }
            try Element.typeText(text, delay: 0.01)
            Thread.sleep(forTimeInterval: 0.1)
            return ToolResult(
                success: true,
                data: ["method": "synthetic-at-focus", "typed": text]
            )
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
                try Element.performHotkey(keys: modifiers + [key])
                FocusManager.clearModifierFlags()
                usleep(10_000) // 10ms for modifier clear to propagate
            } else if let specialKey = mapSpecialKey(key) {
                try Element.typeKey(specialKey)
            } else if key.count == 1 {
                try Element.typeText(key)
            } else {
                return ToolResult(
                    success: false,
                    error: "Unknown key: '\(key)'",
                    suggestion: "Valid: return, tab, escape, space, delete, up, down, left, right, f1-f12"
                )
            }
            return ToolResult(success: true, data: ["key": key])
        } catch {
            return ToolResult(success: false, error: "Key press failed: \(error)")
        }
    }

    // MARK: - ghost_hotkey

    /// Press a key combination. Clears modifier flags after to prevent stuck keys.
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
            // Wait for the hotkey events to be fully processed by the target app
            // BEFORE clearing modifier flags. If we clear too early, Cmd might
            // be released before the Return key event registers with the app.
            usleep(200_000) // 200ms for app to process the hotkey
            // Now safe to clear modifier flags
            FocusManager.clearModifierFlags()
            usleep(10_000) // 10ms for clear event to propagate
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

        let lines = Double(amount ?? 3)
        let deltaY: Double
        let deltaX: Double

        switch direction.lowercased() {
        case "up":    deltaY = lines * 10; deltaX = 0
        case "down":  deltaY = -lines * 10; deltaX = 0
        case "left":  deltaX = lines * 10; deltaY = 0
        case "right": deltaX = -lines * 10; deltaY = 0
        default:
            return ToolResult(success: false, error: "Invalid direction: '\(direction)'")
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
        x: Double?, y: Double?,
        width: Double?, height: Double?
    ) -> ToolResult {
        guard let appElement = Perception.appElement(for: appName) else {
            return ToolResult(success: false, error: "Application '\(appName)' not found")
        }

        if action == "list" {
            guard let windows = appElement.windows() else {
                return ToolResult(success: true, data: ["windows": [] as [Any], "count": 0])
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

        let window: Element? = if let windowTitle {
            appElement.windows()?.first { $0.title()?.localizedCaseInsensitiveContains(windowTitle) == true }
        } else {
            appElement.focusedWindow() ?? appElement.mainWindow()
        }

        guard let window else {
            return ToolResult(
                success: false,
                error: "Window not found in '\(appName)'",
                suggestion: "Use ghost_window with action:'list' to see windows"
            )
        }

        switch action.lowercased() {
        case "minimize":
            _ = window.minimizeWindow()
            return ToolResult(success: true, data: ["action": "minimize"])
        case "maximize":
            _ = window.maximizeWindow()
            return ToolResult(success: true, data: ["action": "maximize"])
        case "close":
            _ = window.closeWindow()
            return ToolResult(success: true, data: ["action": "close"])
        case "restore":
            _ = window.showWindow()
            return ToolResult(success: true, data: ["action": "restore"])
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
            return ToolResult(success: false, error: "Unknown action: '\(action)'")
        }
    }

    // MARK: - Element Finding (shared helper)

    /// Find an element using content-root-first strategy with semantic depth.
    /// Searches AXWebArea first (in-page elements), then full app tree.
    private static func findElement(locator: Locator, appName: String?) -> Element? {
        guard let appElement = resolveAppElement(appName: appName) else { return nil }

        // Content-root-first: search AXWebArea, then full tree
        if let window = appElement.focusedWindow(),
           let webArea = Perception.findWebArea(in: window)
        {
            if let found = searchWithSemanticDepth(locator: locator, root: webArea) {
                return found
            }
        }

        // Full app tree fallback
        return searchWithSemanticDepth(locator: locator, root: appElement)
    }

    /// Search with semantic depth tunneling using AXorcist's Element.searchElements.
    /// Falls back to manual semantic-depth walk if AXorcist doesn't find it.
    private static func searchWithSemanticDepth(locator: Locator, root: Element) -> Element? {
        // Try AXorcist's built-in search first
        if let query = locator.computedNameContains {
            var options = ElementSearchOptions()
            options.maxDepth = GhostConstants.semanticDepthBudget
            if let roleCriteria = locator.criteria.first(where: { $0.attribute == "AXRole" }) {
                options.includeRoles = [roleCriteria.value]
            }
            if let found = root.findElement(matching: query, options: options) {
                return found
            }
        }

        // DOM ID search (bypasses depth limits)
        if let domIdCriteria = locator.criteria.first(where: { $0.attribute == "AXDOMIdentifier" }) {
            return findByDOMId(domIdCriteria.value, in: root, maxDepth: 50)
        }

        return nil
    }

    /// Resolve app name to Element.
    private static func resolveAppElement(appName: String?) -> Element? {
        if let appName {
            return Perception.appElement(for: appName)
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return Element.application(for: frontApp.processIdentifier)
    }

    // MARK: - Field Finding for ghost_type into

    /// Editable/input roles that the 'into' parameter should match against.
    /// When someone says into:"To", they mean a field labeled "To", not
    /// a link that says "Skip to content".
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXSecureTextField",
    ]

    /// Find an editable field by name. Searches ALL matching elements and
    /// scores them, preferring editable roles and exact/prefix matches.
    /// This is the v1 SmartResolver pattern adapted for v2.
    private static func findEditableField(named query: String, appName: String?) -> Element? {
        guard let appElement = resolveAppElement(appName: appName) else { return nil }

        let queryLower = query.lowercased()

        // Search from content root first (web area), then full tree
        let searchRoot: Element
        if let window = appElement.focusedWindow(),
           let webArea = Perception.findWebArea(in: window)
        {
            searchRoot = webArea
        } else if let window = appElement.focusedWindow() {
            searchRoot = window
        } else {
            searchRoot = appElement
        }

        // Collect ALL matching elements with scores.
        // Uses semantic depth (empty layout containers cost 0) so we reach
        // Gmail compose fields at DOM depth 30+ within budget of 25.
        var candidates: [(element: Element, score: Int)] = []
        scoreFieldCandidates(
            element: searchRoot,
            queryLower: queryLower,
            candidates: &candidates,
            semanticDepth: 0,
            maxSemanticDepth: GhostConstants.semanticDepthBudget
        )

        // Return the highest-scoring candidate
        return candidates.max(by: { $0.score < $1.score })?.element
    }

    /// Layout roles that cost zero semantic depth (tunneled through).
    /// Same set used by ghost_read's semantic depth tunneling.
    private static let layoutRoles: Set<String> = [
        "AXGroup", "AXGenericElement", "AXSection", "AXDiv",
        "AXList", "AXLandmarkMain", "AXLandmarkNavigation",
        "AXLandmarkBanner", "AXLandmarkContentInfo",
    ]

    /// Walk the tree scoring elements as field candidates.
    /// Uses SEMANTIC depth (empty layout containers cost 0) so we can
    /// reach Gmail compose fields at DOM depth 30+ within budget of 25.
    private static func scoreFieldCandidates(
        element: Element,
        queryLower: String,
        candidates: inout [(element: Element, score: Int)],
        semanticDepth: Int,
        maxSemanticDepth: Int
    ) {
        guard semanticDepth <= maxSemanticDepth, candidates.count < 100 else { return }

        let role = element.role() ?? ""
        let titleLower = (element.title() ?? "").lowercased()
        let descLower = (element.descriptionText() ?? "").lowercased()
        let nameLower = (element.computedName() ?? "").lowercased()

        // Semantic depth: empty layout containers cost 0
        let hasContent = !titleLower.isEmpty || !descLower.isEmpty || !nameLower.isEmpty
        let isTunnel = layoutRoles.contains(role) && !hasContent
        let childSemanticDepth = isTunnel ? semanticDepth : semanticDepth + 1

        // Score: does this element's name match the query?
        var score = 0

        // Exact match on any name property
        if titleLower == queryLower || descLower == queryLower || nameLower == queryLower {
            score = 100
        }
        // Starts with query
        else if titleLower.hasPrefix(queryLower) || descLower.hasPrefix(queryLower) || nameLower.hasPrefix(queryLower) {
            score = 80
        }
        // Contains query
        else if titleLower.contains(queryLower) || descLower.contains(queryLower) || nameLower.contains(queryLower) {
            score = 60
        }

        if score > 0 {
            // Bonus for editable/interactive roles (the whole point of 'into')
            // High bonus (+50) ensures editable fields always beat links/buttons
            if editableRoles.contains(role) {
                score += 50
            }

            // Bonus for being on-screen (visible) - helps when multiple
            // compose windows exist (old draft vs current compose)
            if let pos = element.position(), let size = element.size() {
                let onScreen = NSScreen.screens.contains { screen in
                    screen.frame.intersects(CGRect(origin: pos, size: size))
                }
                if onScreen && size.width > 1 && size.height > 1 {
                    score += 20
                }
            }

            // Only include if score is reasonable
            if score >= 50 {
                candidates.append((element: element, score: score))
            }
        }

        // Recurse into children with semantic depth
        guard let children = element.children() else { return }
        for child in children {
            scoreFieldCandidates(
                element: child, queryLower: queryLower,
                candidates: &candidates,
                semanticDepth: childSemanticDepth,
                maxSemanticDepth: maxSemanticDepth
            )
        }
    }

    // MARK: - Readback Verification

    /// Read the current value of an element for verification.
    private static func readbackFromElement(_ element: Element) -> String {
        // Try raw AXValue (Chrome compatible)
        if let value = Perception.readValue(from: element), !value.isEmpty {
            return value.count > 200 ? String(value.prefix(200)) + "..." : value
        }
        // Try title (some fields expose typed text as title)
        if let title = element.title(), !title.isEmpty {
            return title.count > 200 ? String(title.prefix(200)) + "..." : title
        }
        // Try computedName
        if let name = element.computedName(), !name.isEmpty {
            return name.count > 200 ? String(name.prefix(200)) + "..." : name
        }
        return "(verification unavailable for this field type)"
    }

    // MARK: - DOM ID Search

    private static func findByDOMId(_ domId: String, in root: Element, maxDepth: Int) -> Element? {
        findByDOMIdWalk(element: root, domId: domId, depth: 0, maxDepth: maxDepth)
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

    // MARK: - Special Key Mapping

    private static func mapSpecialKey(_ key: String) -> SpecialKey? {
        switch key.lowercased() {
        case "return", "enter": .return
        case "tab": .tab
        case "escape", "esc": .escape
        case "space": .space
        case "delete", "backspace": .delete
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "home": .home
        case "end": .end
        case "pageup": .pageUp
        case "pagedown": .pageDown
        case "f1": .f1;  case "f2": .f2;  case "f3": .f3
        case "f4": .f4;  case "f5": .f5;  case "f6": .f6
        case "f7": .f7;  case "f8": .f8;  case "f9": .f9
        case "f10": .f10; case "f11": .f11; case "f12": .f12
        default: nil
        }
    }
}
