// CDPBridge.swift - Chrome DevTools Protocol client for Ghost OS v2
//
// Connects to Chrome's internal debugging port to get instant access to
// the real DOM, CSS selectors, and JavaScript evaluation. This solves
// the web app problem: instead of fighting Chrome's AX tree (where
// everything is AXGroup), we query Chrome's own DOM directly.
//
// Architecture:
//   Ghost OS → WebSocket → Chrome CDP → DOM tree / CSS selectors
//
// Requires Chrome to be running with --remote-debugging-port=9222.
// CDPBridge gracefully handles the case where Chrome isn't running
// with debugging enabled — it's an optional enhancement, not a requirement.
//
// CDP provides:
//   - DOM.getDocument: Full DOM tree
//   - DOM.querySelectorAll: CSS selector queries
//   - DOM.getBoxModel: Element bounding boxes (viewport coordinates)
//   - Runtime.evaluate: Execute JavaScript in page context
//   - Accessibility.getFullAXTree: Chrome's own accessibility tree
//
// For now, we use a simpler approach: Runtime.evaluate to run JavaScript
// that finds elements and returns their coordinates. This avoids the
// complexity of the full DOM/CDP state machine while still being instant.

import Foundation

/// Chrome DevTools Protocol bridge for instant web app element finding.
public enum CDPBridge {

    /// Default Chrome debug port.
    private static let defaultPort = 9222

    /// Timeout for CDP HTTP requests (listing tabs, etc.).
    /// Keep short: called as a fallback in ghost_find/ghost_click hot path.
    /// If Chrome debug port isn't open, connection-refused is instant anyway.
    private static let httpTimeout: TimeInterval = 1.5

    /// Timeout for CDP WebSocket commands.
    /// Keep short: the JS evaluation is fast (<100ms), the timeout is for
    /// cases where Chrome is hung or the WebSocket connection is stale.
    private static let wsTimeout: TimeInterval = 3.0

    // MARK: - Availability Check

    /// Check if Chrome is running with remote debugging enabled.
    public static func isAvailable() -> Bool {
        return getDebugTargets() != nil
    }

    /// Get the list of debuggable Chrome tabs.
    public static func getDebugTargets() -> [[String: Any]]? {
        guard let url = URL(string: "http://127.0.0.1:\(defaultPort)/json") else {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: httpTimeout)
        request.httpMethod = "GET"

        nonisolated final class Box: @unchecked Sendable {
            var data: Data?
            var error: (any Error)?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: request) { data, _, error in
            box.data = data
            box.error = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard box.error == nil,
              let data = box.data,
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        return targets
    }

    // MARK: - Element Finding via JavaScript

    /// Find elements in the active Chrome tab by query text.
    /// Uses Runtime.evaluate to run JavaScript that searches the DOM
    /// and returns element positions in viewport coordinates.
    ///
    /// This is dramatically faster than AX tree walking for web apps
    /// (~50ms vs ~11s for Gmail).
    public static func findElements(
        query: String,
        tabIndex: Int = 0
    ) -> [[String: Any]]? {
        guard let targets = getDebugTargets() else {
            return nil
        }

        // Find the target tab (filter to "page" type, skip extensions/devtools)
        let pages = targets.filter { ($0["type"] as? String) == "page" }
        guard tabIndex < pages.count,
              let wsURL = pages[tabIndex]["webSocketDebuggerUrl"] as? String
        else {
            return nil
        }

        // JavaScript that finds elements by text content, aria-label, placeholder, etc.
        // Returns an array of {text, tag, role, x, y, width, height} objects.
        let js = """
        (function() {
            const query = \(escapeJSString(query));
            const queryLower = query.toLowerCase();
            const results = [];
            const seen = new Set();

            function addResult(el, matchType) {
                const rect = el.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) return;
                if (rect.bottom < 0 || rect.top > window.innerHeight) return;

                const key = `${Math.round(rect.x)},${Math.round(rect.y)}`;
                if (seen.has(key)) return;
                seen.add(key);

                results.push({
                    text: (el.textContent || '').trim().substring(0, 100),
                    tag: el.tagName.toLowerCase(),
                    role: el.getAttribute('role') || '',
                    ariaLabel: el.getAttribute('aria-label') || '',
                    id: el.id || '',
                    className: (el.className || '').toString().substring(0, 100),
                    x: Math.round(rect.x),
                    y: Math.round(rect.y),
                    width: Math.round(rect.width),
                    height: Math.round(rect.height),
                    centerX: Math.round(rect.x + rect.width / 2),
                    centerY: Math.round(rect.y + rect.height / 2),
                    matchType: matchType,
                    actionable: ['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA'].includes(el.tagName) ||
                                el.getAttribute('role') === 'button' ||
                                el.getAttribute('role') === 'link' ||
                                el.getAttribute('role') === 'textbox' ||
                                el.onclick !== null ||
                                el.getAttribute('tabindex') !== null
                });
            }

            // Strategy 1: aria-label match
            document.querySelectorAll('[aria-label]').forEach(el => {
                if (el.getAttribute('aria-label').toLowerCase().includes(queryLower)) {
                    addResult(el, 'aria-label');
                }
            });

            // Strategy 2: placeholder match
            document.querySelectorAll('[placeholder]').forEach(el => {
                if (el.getAttribute('placeholder').toLowerCase().includes(queryLower)) {
                    addResult(el, 'placeholder');
                }
            });

            // Strategy 3: button/link text content match
            document.querySelectorAll('button, a, [role="button"], [role="link"], [role="tab"]').forEach(el => {
                if ((el.textContent || '').toLowerCase().includes(queryLower)) {
                    addResult(el, 'text-content');
                }
            });

            // Strategy 4: input labels
            document.querySelectorAll('label').forEach(label => {
                if ((label.textContent || '').toLowerCase().includes(queryLower)) {
                    const forId = label.getAttribute('for');
                    if (forId) {
                        const input = document.getElementById(forId);
                        if (input) addResult(input, 'label-for');
                    }
                }
            });

            // Strategy 5: title/alt attribute match
            document.querySelectorAll('[title], [alt]').forEach(el => {
                const t = (el.getAttribute('title') || el.getAttribute('alt') || '').toLowerCase();
                if (t.includes(queryLower)) {
                    addResult(el, 'title-attr');
                }
            });

            return results.slice(0, 20);
        })();
        """

        return evaluateJS(js, wsURL: wsURL)
    }

    // MARK: - JavaScript Evaluation

    /// Evaluate JavaScript in the Chrome tab and return the result.
    /// Uses a synchronous WebSocket connection to send a CDP Runtime.evaluate
    /// command and wait for the response.
    private static func evaluateJS(
        _ expression: String,
        wsURL: String
    ) -> [[String: Any]]? {
        guard let url = URL(string: wsURL) else { return nil }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        // Send Runtime.evaluate command
        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "returnByValue": true,
            ],
        ]

        guard let commandData = try? JSONSerialization.data(withJSONObject: command),
              let commandString = String(data: commandData, encoding: .utf8)
        else {
            wsTask.cancel(with: .goingAway, reason: nil)
            return nil
        }

        nonisolated final class ResultBox: @unchecked Sendable {
            var result: [[String: Any]]?
            var error: (any Error)?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        // Send command
        wsTask.send(.string(commandString)) { error in
            if let error {
                box.error = error
                semaphore.signal()
                return
            }

            // Read response
            wsTask.receive { result in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let resultObj = json["result"] as? [String: Any],
                           let resultValue = resultObj["result"] as? [String: Any],
                           let value = resultValue["value"] as? [[String: Any]]
                        {
                            box.result = value
                        }
                    default:
                        break
                    }
                case .failure(let error):
                    box.error = error
                }
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + wsTimeout)
        wsTask.cancel(with: .goingAway, reason: nil)

        if waitResult == .timedOut {
            Log.warn("CDP: WebSocket timeout after \(wsTimeout)s")
            return nil
        }

        return box.result
    }

    // MARK: - Helpers

    /// Escape a string for safe inclusion in JavaScript source code.
    private static func escapeJSString(_ str: String) -> String {
        var escaped = str
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Convert CDP viewport coordinates to screen coordinates.
    /// Chrome's viewport coordinates are relative to the content area.
    /// We need to add the Chrome window's content area offset.
    public static func viewportToScreen(
        viewportX: Double,
        viewportY: Double,
        windowX: Double,
        windowY: Double,
        titleBarHeight: Double = 36  // Chrome's title bar + tab bar height
    ) -> (x: Double, y: Double) {
        // Chrome's content area starts after the title bar and toolbar
        // Typical Chrome toolbar height: ~88px (title bar + tab bar + address bar)
        let toolbarHeight = 88.0
        return (
            x: windowX + viewportX,
            y: windowY + titleBarHeight + toolbarHeight + viewportY
        )
    }
}
