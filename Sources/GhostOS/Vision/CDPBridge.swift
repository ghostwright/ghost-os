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

    // MARK: - Target Cache

    /// Cached debug targets to avoid repeated HTTP calls within a single
    /// findElements invocation chain. Cache is very short-lived (1 second)
    /// since tabs can open/close at any time.
    private static let targetCacheTTL: TimeInterval = 1.0
    private nonisolated(unsafe) static var cachedTargets: [[String: Any]]?
    private nonisolated(unsafe) static var cachedTargetsTime: Date?

    // MARK: - Browser App Detection

    /// Known browser/Electron app names that expose DOM via CDP.
    /// Used by Perception to decide whether to try CDP before AX tree walk.
    private static let browserAppNames = [
        "Google Chrome", "Chrome", "Chromium", "Arc", "Arc Browser",
        "Microsoft Edge", "Brave Browser", "Vivaldi", "Opera",
        // Electron apps (use Chrome's engine, expose CDP when debug port is open)
        "Slack", "Discord", "Visual Studio Code", "Code",
        "Figma", "Notion", "Obsidian", "Cursor",
    ]

    /// Check if an app name corresponds to a Chrome/Electron browser.
    /// Used by Perception.findElements() to decide routing:
    ///   - Browser app → CDP-First path (try CDP before AX tree walk)
    ///   - Native app  → AX-First path (existing behavior, unchanged)
    ///
    /// False positives are safe: CDP will simply return nil and fall through.
    /// False negatives cost ~11s per query (full AX tree walk before CDP).
    public static func isBrowserApp(_ name: String?) -> Bool {
        guard let name else { return false }
        return browserAppNames.contains(where: { name.localizedCaseInsensitiveContains($0) })
    }

    // MARK: - Availability Check

    /// Check if Chrome is running with remote debugging enabled.
    public static func isAvailable() -> Bool {
        return getDebugTargets() != nil
    }

    /// Get the list of debuggable Chrome tabs.
    /// Uses a 1-second cache to avoid repeated HTTP calls during a single
    /// ghost_find → ghost_click sequence.
    public static func getDebugTargets() -> [[String: Any]]? {
        // Return cached targets if fresh enough
        if let cached = cachedTargets,
           let time = cachedTargetsTime,
           Date().timeIntervalSince(time) < targetCacheTTL
        {
            return cached
        }

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
            cachedTargets = nil
            cachedTargetsTime = nil
            return nil
        }

        // Update cache
        cachedTargets = targets
        cachedTargetsTime = Date()

        return targets
    }

    // MARK: - Element Finding via JavaScript

    /// Find elements in the active Chrome tab by query text.
    /// Uses Runtime.evaluate to run JavaScript that searches the DOM
    /// and returns element positions in viewport coordinates.
    ///
    /// This is dramatically faster than AX tree walking for web apps
    /// (~50ms vs ~11s for Gmail).
    ///
    /// Search strategies (executed in order, results deduplicated):
    ///   1. CSS Selector — direct query if input looks like a selector (#id, .class, tag)
    ///   2. data-testid — React/Vue test attribute match
    ///   3. aria-label — ARIA label match (existing)
    ///   4. placeholder — input placeholder match (existing)
    ///   5. role + text — ARIA role with text content match
    ///   6. button/link text — text content of interactive elements (existing)
    ///   7. input labels — label[for] association (existing)
    ///   8. title/alt — title or alt attribute match (existing)
    ///   9. nearest-input — find label text, return nearest input/textarea
    ///  10. Shadow DOM — pierce open shadow roots
    ///  11. fuzzy text — Levenshtein distance <= 2 for typo tolerance
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

        // JavaScript that finds elements using 11 strategies.
        // Returns an array of {text, tag, role, x, y, width, height, ...} objects.
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

                const dataTestId = el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '';
                results.push({
                    text: (el.textContent || '').trim().substring(0, 100),
                    tag: el.tagName.toLowerCase(),
                    role: el.getAttribute('role') || '',
                    ariaLabel: el.getAttribute('aria-label') || '',
                    id: el.id || '',
                    dataTestId: dataTestId,
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
                                el.getAttribute('role') === 'combobox' ||
                                el.getAttribute('role') === 'menuitem' ||
                                el.onclick !== null ||
                                el.getAttribute('tabindex') !== null ||
                                window.getComputedStyle(el).cursor === 'pointer'
                });
            }

            // Strategy 1: CSS Selector — if query starts with #, ., or contains []
            if (/^[#.[]/.test(query) || /\\w+\\[/.test(query)) {
                try {
                    document.querySelectorAll(query).forEach(el => addResult(el, 'css-selector'));
                } catch(e) { /* invalid selector, skip */ }
            }

            // Strategy 2: data-testid match (React/Vue/Angular test attributes)
            document.querySelectorAll('[data-testid], [data-test-id]').forEach(el => {
                const tid = (el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '').toLowerCase();
                if (tid.includes(queryLower)) {
                    addResult(el, 'data-testid');
                }
            });

            // Strategy 3: aria-label match
            document.querySelectorAll('[aria-label]').forEach(el => {
                if (el.getAttribute('aria-label').toLowerCase().includes(queryLower)) {
                    addResult(el, 'aria-label');
                }
            });

            // Strategy 4: placeholder match
            document.querySelectorAll('[placeholder]').forEach(el => {
                if (el.getAttribute('placeholder').toLowerCase().includes(queryLower)) {
                    addResult(el, 'placeholder');
                }
            });

            // Strategy 5: role + aria-label/text combo (ARIA widgets)
            document.querySelectorAll('[role]').forEach(el => {
                const label = el.getAttribute('aria-label') || el.textContent || '';
                if (label.toLowerCase().includes(queryLower)) {
                    addResult(el, 'role-text');
                }
            });

            // Strategy 6: button/link text content match
            document.querySelectorAll('button, a, [role="button"], [role="link"], [role="tab"], [role="menuitem"]').forEach(el => {
                if ((el.textContent || '').toLowerCase().includes(queryLower)) {
                    addResult(el, 'text-content');
                }
            });

            // Strategy 7: input labels
            document.querySelectorAll('label').forEach(label => {
                if ((label.textContent || '').toLowerCase().includes(queryLower)) {
                    const forId = label.getAttribute('for');
                    if (forId) {
                        const input = document.getElementById(forId);
                        if (input) addResult(input, 'label-for');
                    }
                }
            });

            // Strategy 8: title/alt attribute match
            document.querySelectorAll('[title], [alt]').forEach(el => {
                const t = (el.getAttribute('title') || el.getAttribute('alt') || '').toLowerCase();
                if (t.includes(queryLower)) {
                    addResult(el, 'title-attr');
                }
            });

            // Strategy 9: nearest-input — find text, return the closest input/textarea
            if (results.length === 0) {
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                while (walker.nextNode()) {
                    if (walker.currentNode.textContent.toLowerCase().includes(queryLower)) {
                        let parent = walker.currentNode.parentElement;
                        for (let i = 0; i < 5 && parent; i++) {
                            const input = parent.querySelector('input, textarea, select, [contenteditable="true"]');
                            if (input) { addResult(input, 'nearest-input'); break; }
                            parent = parent.parentElement;
                        }
                    }
                }
            }

            // Strategy 10: Shadow DOM — pierce open shadow roots (Web Components)
            if (results.length === 0) {
                function searchShadow(root) {
                    root.querySelectorAll('*').forEach(el => {
                        if (el.shadowRoot) {
                            el.shadowRoot.querySelectorAll('[aria-label], button, a, [role="button"], input').forEach(inner => {
                                const label = inner.getAttribute('aria-label') || inner.textContent || '';
                                if (label.toLowerCase().includes(queryLower)) {
                                    addResult(inner, 'shadow-dom');
                                }
                            });
                            searchShadow(el.shadowRoot);
                        }
                    });
                }
                searchShadow(document);
            }

            // Strategy 11: fuzzy text match (Levenshtein distance <= 2)
            if (results.length === 0 && query.length >= 3) {
                function levenshtein(a, b) {
                    const m = a.length, n = b.length;
                    if (Math.abs(m - n) > 2) return 3;
                    const d = Array.from({length: m + 1}, (_, i) => [i]);
                    for (let j = 1; j <= n; j++) d[0][j] = j;
                    for (let i = 1; i <= m; i++)
                        for (let j = 1; j <= n; j++)
                            d[i][j] = Math.min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+(a[i-1]!==b[j-1]?1:0));
                    return d[m][n];
                }
                document.querySelectorAll('button, a, [role="button"], [role="link"], input, [role="tab"]').forEach(el => {
                    const text = (el.getAttribute('aria-label') || el.textContent || '').trim().toLowerCase();
                    if (text.length > 0 && text.length < 50) {
                        const words = text.split(/\\s+/);
                        for (const word of words) {
                            if (levenshtein(queryLower, word) <= 2) {
                                addResult(el, 'fuzzy-text');
                                break;
                            }
                        }
                    }
                });
            }

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
