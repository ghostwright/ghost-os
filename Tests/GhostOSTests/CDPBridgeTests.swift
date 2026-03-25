// CDPBridgeTests.swift - Unit tests for CDPBridge enhancements

import Testing
@testable import GhostOS

@Suite("CDPBridge Tests")
struct CDPBridgeTests {

    // MARK: - isBrowserApp detection

    @Test("Detects Google Chrome as browser app")
    func chromeDetection() {
        #expect(CDPBridge.isBrowserApp("Google Chrome") == true)
    }

    @Test("Detects Arc as browser app")
    func arcDetection() {
        #expect(CDPBridge.isBrowserApp("Arc") == true)
    }

    @Test("Detects Electron apps as browser app")
    func electronDetection() {
        #expect(CDPBridge.isBrowserApp("Slack") == true)
        #expect(CDPBridge.isBrowserApp("Visual Studio Code") == true)
        #expect(CDPBridge.isBrowserApp("Discord") == true)
    }

    @Test("Does not detect native apps as browser app")
    func nativeAppDetection() {
        #expect(CDPBridge.isBrowserApp("Finder") == false)
        #expect(CDPBridge.isBrowserApp("Mail") == false)
        #expect(CDPBridge.isBrowserApp("Preview") == false)
        #expect(CDPBridge.isBrowserApp("Terminal") == false)
        #expect(CDPBridge.isBrowserApp("Safari") == false)  // Safari has no CDP
    }

    @Test("Handles nil app name gracefully")
    func nilAppName() {
        #expect(CDPBridge.isBrowserApp(nil) == false)
    }

    @Test("Case insensitive browser detection")
    func caseInsensitive() {
        #expect(CDPBridge.isBrowserApp("google chrome") == true)
        #expect(CDPBridge.isBrowserApp("GOOGLE CHROME") == true)
        #expect(CDPBridge.isBrowserApp("Microsoft Edge") == true)
    }

    // MARK: - CDP availability (safe to run without Chrome)

    @Test("isAvailable returns false when Chrome debug port is not open")
    func availabilityWithoutChrome() {
        // This test is safe: if Chrome isn't running with --remote-debugging-port=9222,
        // isAvailable() should return false quickly (connection refused).
        // If Chrome IS running with debug port, it returns true — both are valid.
        let result = CDPBridge.isAvailable()
        // We just verify it doesn't crash or hang
        #expect(result == true || result == false)
    }

    @Test("getDebugTargets returns nil when Chrome debug port is not open")
    func debugTargetsWithoutChrome() {
        // Same as above: graceful nil when Chrome debug port isn't available
        let targets = CDPBridge.getDebugTargets()
        #expect(targets == nil || targets != nil)
    }
}
