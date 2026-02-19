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
        if let appName {
            guard let app = findApp(named: appName) else {
                return ToolResult(
                    success: false,
                    error: "Application '\(appName)' not found or not running",
                    suggestion: "Use ghost_state to see all running apps"
                )
            }
            return buildContext(for: app)
        } else {
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

    // MARK: - ghost_find

    /// Find elements matching criteria in any app.
    public static func findElements(
        query: String?,
        role: String?,
        domId: String?,
        domClass: String?,
        identifier: String?,
        appName: String?,
        depth: Int?
    ) -> ToolResult {
        // Need at least one search criterion
        guard query != nil || role != nil || domId != nil || identifier != nil || domClass != nil else {
            return ToolResult(
                success: false,
                error: "At least one search parameter required (query, role, dom_id, identifier, or dom_class)",
                suggestion: "Use ghost_context to see what's on screen first"
            )
        }

        // Find the app element to search within
        let searchRoot: Element
        if let appName {
            guard let app = findApp(named: appName),
                  let appElement = Element.application(for: app.processIdentifier)
            else {
                return ToolResult(
                    success: false,
                    error: "Application '\(appName)' not found",
                    suggestion: "Use ghost_state to see all running apps"
                )
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

        let maxDepth = min(depth ?? GhostConstants.semanticDepthBudget, GhostConstants.maxSearchDepth)

        // Strategy 1: DOM ID (most precise, bypasses depth limits)
        if let domId {
            if let element = findByDOMId(domId, in: searchRoot, maxDepth: maxDepth) {
                return ToolResult(success: true, data: ["elements": [elementSummary(element)], "count": 1])
            }
            return ToolResult(
                success: true,
                data: ["elements": [] as [Any], "count": 0],
                suggestion: "No element with DOM id '\(domId)' found. Try ghost_read to see what's on the page."
            )
        }

        // Strategy 2: AXorcist's search with ElementSearchOptions
        var options = ElementSearchOptions()
        options.maxDepth = maxDepth
        options.caseInsensitive = true
        if let role {
            options.includeRoles = [role]
        }

        var results: [Element] = []

        if let identifier {
            if let el = searchRoot.findElement(byIdentifier: identifier) {
                results = [el]
            }
        } else if let query {
            results = searchRoot.searchElements(matching: query, options: options)
        } else if let role {
            results = searchRoot.searchElements(byRole: role, options: options)
        }

        // Also try semantic-depth search if AXorcist search yields nothing
        if results.isEmpty, let query {
            results = semanticDepthSearch(query: query, role: role, in: searchRoot, maxDepth: maxDepth)
        }

        // Cap results to avoid huge responses
        let capped = Array(results.prefix(50))
        let summaries = capped.map { elementSummary($0) }

        return ToolResult(
            success: true,
            data: [
                "elements": summaries,
                "count": summaries.count,
                "total_matches": results.count,
            ]
        )
    }

    // MARK: - ghost_read

    /// Read text content from screen using semantic depth tunneling.
    public static func readContent(appName: String?, query: String?, depth: Int?) -> ToolResult {
        let searchRoot: Element
        if let appName {
            guard let app = findApp(named: appName),
                  let appElement = Element.application(for: app.processIdentifier)
            else {
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

        let maxDepth = depth ?? GhostConstants.semanticDepthBudget

        // If query provided, narrow to that element first
        var readRoot = searchRoot
        if let query {
            var options = ElementSearchOptions()
            options.maxDepth = maxDepth
            if let found = searchRoot.findElement(matching: query, options: options) {
                readRoot = found
            }
        } else {
            // For web apps, start from AXWebArea for better depth reach
            if let window = searchRoot.focusedWindow(),
               let webArea = findWebArea(in: window)
            {
                readRoot = webArea
            } else if let window = searchRoot.focusedWindow() {
                readRoot = window
            }
        }

        // Use semantic depth tunneling to extract content
        var items: [String] = []
        collectContent(from: readRoot, items: &items, semanticDepth: 0, maxSemanticDepth: maxDepth)

        return ToolResult(
            success: true,
            data: [
                "content": items.joined(separator: "\n"),
                "item_count": items.count,
            ]
        )
    }

    // MARK: - ghost_inspect

    /// Full metadata about one element.
    public static func inspect(
        query: String,
        role: String?,
        domId: String?,
        appName: String?
    ) -> ToolResult {
        let searchRoot: Element
        if let appName {
            guard let app = findApp(named: appName),
                  let appElement = Element.application(for: app.processIdentifier)
            else {
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

        // Find the element
        let element: Element?
        if let domId {
            element = findByDOMId(domId, in: searchRoot, maxDepth: GhostConstants.semanticDepthBudget)
        } else {
            var options = ElementSearchOptions()
            options.maxDepth = GhostConstants.semanticDepthBudget
            if let role { options.includeRoles = [role] }
            element = searchRoot.findElement(matching: query, options: options)
        }

        guard let element else {
            return ToolResult(
                success: false,
                error: "Element '\(query)' not found",
                suggestion: "Try ghost_find to see what elements are available, or ghost_context for orientation"
            )
        }

        return ToolResult(success: true, data: fullElementInfo(element))
    }

    // MARK: - ghost_element_at

    /// Get element at screen coordinates.
    public static func elementAt(x: Double, y: Double) -> ToolResult {
        let point = CGPoint(x: x, y: y)

        guard let element = Element.elementAtPoint(point) else {
            return ToolResult(
                success: false,
                error: "No element found at (\(Int(x)), \(Int(y)))",
                suggestion: "Coordinates may be outside any window. Use ghost_state to see window positions."
            )
        }

        return ToolResult(success: true, data: fullElementInfo(element))
    }

    // MARK: - ghost_screenshot

    /// Take a screenshot of an app window.
    public static func screenshot(appName: String?, fullResolution: Bool) -> ToolResult {
        let targetApp: NSRunningApplication
        if let appName {
            guard let app = findApp(named: appName) else {
                return ToolResult(success: false, error: "Application '\(appName)' not found")
            }
            targetApp = app
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return ToolResult(success: false, error: "No frontmost application")
            }
            targetApp = frontApp
        }

        // ScreenCaptureKit is async - bridge to sync with RunLoop spinning
        let pid = targetApp.processIdentifier
        let result = captureScreenshotSync(pid: pid, fullResolution: fullResolution)

        guard let result else {
            return ToolResult(
                success: false,
                error: "Screenshot capture failed",
                suggestion: "Ensure Screen Recording permission is granted in System Settings > Privacy & Security > Screen Recording"
            )
        }

        return ToolResult(
            success: true,
            data: [
                "image": result.base64PNG,
                "width": result.width,
                "height": result.height,
                "window_title": result.windowTitle as Any,
                "mime_type": "image/png",
            ]
        )
    }

    // MARK: - App Lookup

    /// Find a running app by name (case-insensitive, contains match).
    static func findApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveContains(name) == true
        }
    }

    /// Get the app Element for a named app.
    static func appElement(for name: String) -> Element? {
        guard let app = findApp(named: name) else { return nil }
        return Element.application(for: app.processIdentifier)
    }

    // MARK: - Context Builder

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

        // Interactive elements (buttons, links, fields - just names and roles, not full tree)
        if let window = appElement.focusedWindow() {
            let interactiveRoles: Set<String> = [
                "AXButton", "AXLink", "AXTextField", "AXTextArea",
                "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                "AXComboBox", "AXMenuButton", "AXTab",
            ]
            var interactives: [[String: String]] = []
            collectInteractiveElements(
                from: window, roles: interactiveRoles,
                results: &interactives, depth: 0, maxDepth: 8
            )
            if !interactives.isEmpty {
                data["interactive_elements"] = Array(interactives.prefix(30))
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

    /// Collect interactive elements (buttons, links, fields) for context.
    private static func collectInteractiveElements(
        from element: Element,
        roles: Set<String>,
        results: inout [[String: String]],
        depth: Int,
        maxDepth: Int
    ) {
        guard depth < maxDepth, results.count < 30 else { return }

        if let role = element.role(), roles.contains(role) {
            var info: [String: String] = ["role": role]
            if let name = element.computedName() { info["name"] = name }
            else if let title = element.title() { info["name"] = title }
            if info["name"] != nil {
                results.append(info)
            }
        }

        guard let children = element.children() else { return }
        for child in children {
            collectInteractiveElements(from: child, roles: roles, results: &results, depth: depth + 1, maxDepth: maxDepth)
        }
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

    // MARK: - Element Summary

    /// Build a concise summary of an element (for ghost_find results).
    private static func elementSummary(_ element: Element) -> [String: Any] {
        var info: [String: Any] = [:]
        if let role = element.role() { info["role"] = role }
        if let name = element.computedName() { info["name"] = name }
        else if let title = element.title() { info["name"] = title }
        if let pos = element.position() { info["position"] = ["x": Int(pos.x), "y": Int(pos.y)] }
        if let size = element.size() { info["size"] = ["width": Int(size.width), "height": Int(size.height)] }
        info["actionable"] = element.isActionable()
        if let actions = element.supportedActions(), !actions.isEmpty {
            info["actions"] = actions
        }
        // Include DOM id if available (useful for web apps)
        if let domId = readDOMId(from: element) {
            info["dom_id"] = domId
        }
        if let identifier = element.identifier() {
            info["identifier"] = identifier
        }
        return info
    }

    /// Build full metadata for an element (for ghost_inspect).
    private static func fullElementInfo(_ element: Element) -> [String: Any] {
        var info: [String: Any] = [:]

        // Core identity
        if let role = element.role() { info["role"] = role }
        if let subrole = element.subrole() { info["subrole"] = subrole }
        if let title = element.title() { info["title"] = title }
        if let name = element.computedName() { info["computed_name"] = name }
        if let identifier = element.identifier() { info["identifier"] = identifier }
        if let desc = element.descriptionText() { info["description"] = desc }
        if let help = element.help() { info["help"] = help }

        // DOM attributes
        if let domId = readDOMId(from: element) { info["dom_id"] = domId }
        if let domClasses = readDOMClasses(from: element) { info["dom_classes"] = domClasses }

        // Geometry
        if let pos = element.position() { info["position"] = ["x": Int(pos.x), "y": Int(pos.y)] }
        if let size = element.size() { info["size"] = ["width": Int(size.width), "height": Int(size.height)] }
        if let frame = element.frame() {
            info["frame"] = ["x": Int(frame.origin.x), "y": Int(frame.origin.y),
                             "width": Int(frame.width), "height": Int(frame.height)]
        }

        // State
        info["actionable"] = element.isActionable()
        info["editable"] = element.isEditable()
        if let enabled = element.isEnabled() { info["enabled"] = enabled }
        if let focused = element.isFocused() { info["focused"] = focused }
        if let hidden = element.isHidden() { info["hidden"] = hidden }
        if let busy = element.isElementBusy() { info["busy"] = busy }
        if let modal = element.isModal() { info["modal"] = modal }

        // Actions
        if let actions = element.supportedActions(), !actions.isEmpty {
            info["supported_actions"] = actions
        }

        // Value / text
        if let value = readValue(from: element) { info["value"] = value }
        if let selectedText = element.selectedText() { info["selected_text"] = selectedText }
        if let placeholder = element.placeholderValue() { info["placeholder"] = placeholder }

        // Children count
        if let children = element.children() {
            info["child_count"] = children.count
        }

        // Parent role
        if let parent = element.parent(), let parentRole = parent.role() {
            info["parent_role"] = parentRole
        }

        return info
    }

    // MARK: - Semantic Depth Tunneling

    /// Collect text content with semantic depth tunneling.
    /// Empty layout containers (AXGroup with no content) are traversed at zero depth cost.
    private static func collectContent(
        from element: Element,
        items: inout [String],
        semanticDepth: Int,
        maxSemanticDepth: Int
    ) {
        guard semanticDepth <= maxSemanticDepth else { return }

        // Check if this element has meaningful content
        let hasContent = hasSemanticContent(element)
        let currentDepth = hasContent ? semanticDepth + 1 : semanticDepth

        // Extract text from this element
        if hasContent {
            var text = ""
            if element.role() != nil {
                // Read value, handling Chrome AXStaticText bug
                if let value = readValue(from: element) {
                    text = value
                } else if let title = element.title() {
                    text = title
                } else if let name = element.computedName() {
                    text = name
                }
            }
            if !text.isEmpty {
                let role = element.role() ?? ""
                let prefix = role.hasPrefix("AXHeading") ? "# " :
                             role == "AXLink" ? "[link] " :
                             role == "AXButton" ? "[button] " : ""
                items.append("\(prefix)\(text)")
            }
        }

        // Recurse into children
        guard let children = element.children() else { return }
        for child in children {
            collectContent(from: child, items: &items, semanticDepth: currentDepth, maxSemanticDepth: maxSemanticDepth)
        }
    }

    /// Check if an element has semantic content (vs. empty layout container).
    private static func hasSemanticContent(_ element: Element) -> Bool {
        let role = element.role() ?? ""
        // Empty layout containers tunnel through at zero cost
        let layoutRoles: Set<String> = [
            "AXGroup", "AXGenericElement", "AXSection", "AXDiv",
            "AXList", "AXLandmarkMain", "AXLandmarkNavigation",
            "AXLandmarkBanner", "AXLandmarkContentInfo",
        ]
        if layoutRoles.contains(role) {
            // Only costs depth if it has actual text content
            if element.title() != nil { return true }
            if readValue(from: element) != nil { return true }
            if element.descriptionText() != nil { return true }
            return false
        }
        return true
    }

    // MARK: - Semantic Depth Search

    /// Search with semantic depth tunneling (finds elements AXorcist's flat search misses).
    private static func semanticDepthSearch(
        query: String,
        role: String?,
        in root: Element,
        maxDepth: Int
    ) -> [Element] {
        var results: [Element] = []
        semanticSearchWalk(
            element: root, query: query.lowercased(), role: role,
            results: &results, semanticDepth: 0, maxDepth: maxDepth
        )
        return results
    }

    private static func semanticSearchWalk(
        element: Element,
        query: String,
        role: String?,
        results: inout [Element],
        semanticDepth: Int,
        maxDepth: Int
    ) {
        guard semanticDepth <= maxDepth, results.count < 50 else { return }

        let hasContent = hasSemanticContent(element)
        let currentDepth = hasContent ? semanticDepth + 1 : semanticDepth

        // Check if this element matches
        if let role, element.role() != role {
            // Role doesn't match, skip this element but keep searching children
        } else {
            let name = element.computedName()?.lowercased() ?? ""
            let title = element.title()?.lowercased() ?? ""
            let value = readValue(from: element)?.lowercased() ?? ""
            let desc = element.descriptionText()?.lowercased() ?? ""
            let identifier = element.identifier()?.lowercased() ?? ""

            if name.contains(query) || title.contains(query) || value.contains(query)
                || desc.contains(query) || identifier.contains(query)
            {
                results.append(element)
            }
        }

        guard let children = element.children() else { return }
        for child in children {
            semanticSearchWalk(
                element: child, query: query, role: role,
                results: &results, semanticDepth: currentDepth, maxDepth: maxDepth
            )
        }
    }

    // MARK: - DOM Helpers

    /// Find element by DOM id (searches deep, ignoring depth budget for exact ID match).
    private static func findByDOMId(_ domId: String, in root: Element, maxDepth: Int) -> Element? {
        findByDOMIdWalk(element: root, domId: domId, depth: 0, maxDepth: max(maxDepth, 50))
    }

    private static func findByDOMIdWalk(element: Element, domId: String, depth: Int, maxDepth: Int) -> Element? {
        guard depth < maxDepth else { return nil }

        if let elDomId = readDOMId(from: element), elDomId == domId {
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

    /// Read DOM identifier from an element.
    private static func readDOMId(from element: Element) -> String? {
        if let cfValue = element.rawAttributeValue(named: "AXDOMIdentifier") {
            return cfValue as? String
        }
        return nil
    }

    /// Read DOM class list from an element.
    private static func readDOMClasses(from element: Element) -> String? {
        if let cfValue = element.rawAttributeValue(named: "AXDOMClassList") {
            if let str = cfValue as? String { return str }
            if let arr = cfValue as? [String] { return arr.joined(separator: " ") }
        }
        return nil
    }

    // MARK: - Value Reading

    /// Read element value, working around AXorcist's Chrome AXStaticText bug.
    static func readValue(from element: Element) -> String? {
        // Try AXorcist's typed accessor first
        if let val = element.value() {
            if let str = val as? String, !str.isEmpty { return str }
        }
        // Fall back to raw API for Chrome compatibility
        if let cfValue = element.rawAttributeValue(named: "AXValue") {
            if let str = cfValue as? String, !str.isEmpty { return str }
            if CFGetTypeID(cfValue) == CFStringGetTypeID() {
                let str = (cfValue as! CFString) as String
                if !str.isEmpty { return str }
            }
        }
        return nil
    }

    // MARK: - Web Area / URL

    /// Find AXWebArea element within a window (for reading URLs from browsers).
    static func findWebArea(in element: Element, depth: Int = 0) -> Element? {
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

    /// Read URL from an element.
    static func readURL(from element: Element) -> String? {
        if let url = element.url() {
            return url.absoluteString
        }
        if let cfValue = element.rawAttributeValue(named: "AXURL") {
            if let url = cfValue as? URL { return url.absoluteString }
            if CFGetTypeID(cfValue) == CFURLGetTypeID() {
                return (cfValue as! CFURL as URL).absoluteString
            }
        }
        return nil
    }

    // MARK: - Sync Screenshot Bridge

    /// Bridge ScreenCaptureKit's async API to synchronous using RunLoop spinning.
    /// This avoids Sendable issues with Task.detached and semaphores.
    nonisolated private static func captureScreenshotSync(
        pid: pid_t,
        fullResolution: Bool
    ) -> ScreenshotResult? {
        var result: ScreenshotResult?
        var done = false

        // Use nonisolated detached task to avoid MainActor Sendable issues
        let pidCopy = pid
        let fullResCopy = fullResolution
        Task.detached { @Sendable in
            let r = await ScreenCapture.captureWindow(
                pid: pidCopy,
                fullResolution: fullResCopy
            )
            await MainActor.run {
                result = r
                done = true
            }
        }

        // Spin RunLoop until done or timeout (10 seconds)
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        return result
    }
}
