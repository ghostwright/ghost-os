// EventHandlers.swift - Per-event-type handling with AX enrichment
//
// Called from LearningRecorder.handleEvent() on the learning thread.
// All AX calls use the raw C API (AXUIElementCopyElementAtPosition,
// AXUIElementCopyAttributeValue) to avoid @MainActor isolation.

import ApplicationServices
import AppKit
import Foundation

/// Handles individual CGEvent types during learning.
/// nonisolated because all methods run on the learning thread.
nonisolated enum EventHandlers {

    // MARK: - Key Down

    static func handleKeyDown(_ event: CGEvent, recorder: LearningRecorder) {
        // Never record password keystrokes
        if isSecureFieldFocused() {
            recorder.flushPendingKeystrokesOnLearningThread()
            let (app, bid) = currentAppInfo()
            recorder.appendAction(ObservedAction(
                timestamp: mach_absolute_time(), action: .secureField,
                appName: app, appBundleId: bid,
                windowTitle: nil, url: nil, elementContext: nil
            ))
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("cmd") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskAlternate) { mods.append("option") }
        if flags.contains(.maskControl) { mods.append("control") }
        let hasShortcutModifier = flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)

        let chars = keyChars(from: event)

        if let chars, !hasShortcutModifier {
            // Coalesce character keys into pending buffer
            recorder.withLock { session in
                guard session != nil else { return }
                if recorder.pendingKeystrokes.isEmpty {
                    recorder.pendingKeystrokeElement = focusedFieldContext()
                    recorder.pendingKeystrokeTimestamp = mach_absolute_time()
                    let (app, bid) = currentAppInfo()
                    recorder.pendingKeystrokeApp = app
                    recorder.pendingKeystrokeBundleId = bid
                    recorder.pendingKeystrokeWindow = currentWindowTitle()
                    recorder.pendingKeystrokeUrl = currentURL()
                }
                recorder.pendingKeystrokes.append(chars)
            }
            recorder.scheduleKeystrokeFlushTimer()
        } else {
            // Non-character key or modifier combo: flush pending, record discrete action
            recorder.flushPendingKeystrokesOnLearningThread()
            let keyName = keyNameForCode(keyCode)
            let (app, bid) = currentAppInfo()
            let actionType: ObservedActionType = !mods.isEmpty
                ? .hotkey(modifiers: mods, keyName: keyName)
                : .keyPress(keyCode: keyCode, keyName: keyName, modifiers: [])
            recorder.appendAction(ObservedAction(
                timestamp: mach_absolute_time(), action: actionType,
                appName: app, appBundleId: bid,
                windowTitle: currentWindowTitle(), url: nil, elementContext: nil
            ))
        }
    }

    // MARK: - Mouse Down

    static func handleMouseDown(_ type: CGEventType, _ event: CGEvent, recorder: LearningRecorder) {
        recorder.flushPendingKeystrokesOnLearningThread()
        recorder.flushPendingScrollOnLearningThread()

        let loc = event.location
        let button: String = (type == .leftMouseDown) ? "left" : "right"
        let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
        let (app, bid) = currentAppInfo()

        recorder.appendAction(ObservedAction(
            timestamp: mach_absolute_time(),
            action: .click(x: Double(loc.x), y: Double(loc.y), button: button, count: clicks),
            appName: app, appBundleId: bid,
            windowTitle: currentWindowTitle(), url: currentURL(),
            elementContext: enrichClick(at: loc)
        ))
    }

    // MARK: - Scroll

    static func handleScroll(_ event: CGEvent, recorder: LearningRecorder) {
        let dy = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let dx = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        guard dx != 0 || dy != 0 else { return }

        recorder.flushPendingKeystrokesOnLearningThread()
        let loc = event.location
        let (app, bid) = currentAppInfo()

        recorder.withLock { session in
            guard session != nil else { return }
            if recorder.pendingScrollDeltaX == 0 && recorder.pendingScrollDeltaY == 0 {
                recorder.pendingScrollTimestamp = mach_absolute_time()
                recorder.pendingScrollApp = app
                recorder.pendingScrollBundleId = bid
                recorder.pendingScrollX = Double(loc.x)
                recorder.pendingScrollY = Double(loc.y)
            }
            recorder.pendingScrollDeltaX += dx
            recorder.pendingScrollDeltaY += dy
        }
        recorder.scheduleScrollFlushTimer()
    }

    // MARK: - AX Enrichment

    /// Hit-test at click point to identify the element.
    private static func enrichClick(at location: CGPoint) -> ElementContext? {
        let sys = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(sys, Float(location.x), Float(location.y), &element)
        guard err == .success, let el = element else { return nil }

        let role = axAttr(el, kAXRoleAttribute) as? String
        let title = (axAttr(el, kAXTitleAttribute) as? String).map { String($0.prefix(200)) }
        let ident = (axAttr(el, kAXIdentifierAttribute) as? String).map { String($0.prefix(200)) }
        let domId = axAttr(el, "AXDOMIdentifier") as? String
        let domClasses: String? = {
            guard let v = axAttr(el, "AXDOMClassList") else { return nil }
            if let s = v as? String { return s }
            if let a = v as? [String] { return a.joined(separator: " ") }
            return nil
        }()
        let desc = (axAttr(el, kAXDescriptionAttribute) as? String).map { String($0.prefix(200)) }
        var parentRole: String?
        if let pv = axAttr(el, kAXParentAttribute) {
            // CF types: AXUIElement downcast always succeeds (CFTypeRef bridging)
            parentRole = axAttr(pv as! AXUIElement, kAXRoleAttribute) as? String
        }
        return ElementContext(role: role, title: title, identifier: ident,
            domId: domId, domClasses: domClasses,
            computedName: title ?? desc, parentRole: parentRole)
    }

    /// Get AX context for the currently focused element (typing context).
    private static func focusedFieldContext() -> ElementContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let fv = axAttr(appEl, kAXFocusedUIElementAttribute) else { return nil }
        let el = fv as! AXUIElement  // CF type: downcast always succeeds
        let role = axAttr(el, kAXRoleAttribute) as? String
        let title = (axAttr(el, kAXTitleAttribute) as? String).map { String($0.prefix(200)) }
        let desc = (axAttr(el, kAXDescriptionAttribute) as? String).map { String($0.prefix(200)) }
        let domId = axAttr(el, "AXDOMIdentifier") as? String
        let ident = (axAttr(el, kAXIdentifierAttribute) as? String).map { String($0.prefix(200)) }
        return ElementContext(role: role, title: title, identifier: ident,
            domId: domId, domClasses: nil, computedName: title ?? desc, parentRole: nil)
    }

    // MARK: - Secure Field Detection

    /// Three-tier check: (1) AXSecureTextField role, (2) subrole,
    /// (3) name heuristics for Chrome which renders password fields as AXTextField.
    private static func isSecureFieldFocused() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let fv = axAttr(appEl, kAXFocusedUIElementAttribute) else { return false }
        let focused = fv as! AXUIElement  // CF type: downcast always succeeds

        let role = axAttr(focused, kAXRoleAttribute) as? String
        if role == "AXSecureTextField" { return true }
        let subrole = axAttr(focused, kAXSubroleAttribute) as? String
        if subrole == "AXSecureTextField" { return true }

        let title = (axAttr(focused, kAXTitleAttribute) as? String ?? "").lowercased()
        let desc = (axAttr(focused, kAXDescriptionAttribute) as? String ?? "").lowercased()
        let id = (axAttr(focused, kAXIdentifierAttribute) as? String ?? "").lowercased()
        return LearningConstants.sensitiveFieldPatterns.contains { p in
            title.contains(p) || desc.contains(p) || id.contains(p)
        }
    }

    // MARK: - Helpers

    private static func axAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func currentAppInfo() -> (name: String, bundleId: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("Unknown", "") }
        return (app.localizedName ?? "Unknown", app.bundleIdentifier ?? "")
    }

    static func currentWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let wv = axAttr(appEl, kAXFocusedWindowAttribute) else { return nil }
        let win = wv as! AXUIElement  // CF type: downcast always succeeds
        return (axAttr(win, kAXTitleAttribute) as? String).map { String($0.prefix(200)) }
    }

    static func currentURL() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else { return nil }
        let browsers: Set<String> = [
            "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
            "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
        ]
        guard browsers.contains(bid) else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let wv = axAttr(appEl, kAXFocusedWindowAttribute) else { return nil }
        let win = wv as! AXUIElement  // CF type: downcast always succeeds
        return findURLField(in: win, depth: 0)
    }

    private static func findURLField(in el: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        let role = axAttr(el, kAXRoleAttribute) as? String
        if role == "AXTextField" || role == "AXComboBox" {
            let desc = (axAttr(el, kAXDescriptionAttribute) as? String ?? "").lowercased()
            if desc.contains("address") || desc.contains("url") || desc.contains("search or enter") {
                return axAttr(el, kAXValueAttribute) as? String
            }
        }
        guard let children = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let url = findURLField(in: child, depth: depth + 1) { return url }
        }
        return nil
    }

    private static func keyChars(from event: CGEvent) -> String? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        guard let chars = nsEvent.characters, !chars.isEmpty else { return nil }
        if chars.unicodeScalars.allSatisfy({ $0.value < 32 || $0.value == 127 }) { return nil }
        return chars
    }

    static func keyNameForCode(_ code: Int) -> String {
        switch code {
        case 36: "return"; case 48: "tab"; case 49: "space"; case 51: "delete"
        case 53: "escape"; case 123: "left"; case 124: "right"; case 125: "down"
        case 126: "up"; case 115: "home"; case 119: "end"; case 116: "pageup"
        case 121: "pagedown"; case 117: "forwarddelete"
        case 122: "f1"; case 120: "f2"; case 99: "f3"; case 118: "f4"
        case 96: "f5"; case 97: "f6"; case 98: "f7"; case 100: "f8"
        case 101: "f9"; case 109: "f10"; case 103: "f11"; case 111: "f12"
        default: "key\(code)"
        }
    }
}
