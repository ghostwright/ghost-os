// VisionPerception.swift - Vision-based perception tools for Ghost OS v2
//
// Maps to MCP tools: ghost_parse_screen, ghost_ground
//
// These tools use the Python vision sidecar (localhost:9876) for ML inference.
// The sidecar handles ShowUI-2B (VLM grounding) and future YOLO detection.
//
// Architecture:
//   ghost_parse_screen → screenshot → sidecar /detect → structured elements
//   ghost_ground       → screenshot → sidecar /ground → (x, y) coordinates
//
// Both tools take a screenshot automatically using the existing ScreenCapture
// module, then send it to the sidecar for processing.

import AppKit
import Foundation

/// Vision-based perception: when the AX tree isn't enough.
public enum VisionPerception {

    // MARK: - ghost_parse_screen

    /// Detect all interactive UI elements using vision.
    /// Takes a screenshot and sends it to the vision sidecar for YOLO detection.
    public static func parseScreen(
        appName: String?,
        fullResolution: Bool
    ) -> ToolResult {
        // Check sidecar availability
        guard VisionBridge.isAvailable() else {
            return sidecarUnavailableResult(tool: "ghost_parse_screen")
        }

        // Take screenshot
        guard let screenshot = captureForVision(appName: appName, fullResolution: fullResolution) else {
            return ToolResult(
                success: false,
                error: "Screenshot capture failed",
                suggestion: "Ensure Screen Recording permission is granted"
            )
        }

        // For now, return the health status since YOLO detection is not yet implemented.
        // When implemented, this will call /detect and return structured elements.
        let health = VisionBridge.healthCheck()
        return ToolResult(
            success: true,
            data: [
                "note": "YOLO element detection not yet implemented. Vision sidecar is running.",
                "sidecar_status": health?["status"] as? String ?? "unknown",
                "models_loaded": health?["models_loaded"] as? [String] ?? [],
                "screenshot_width": screenshot.width,
                "screenshot_height": screenshot.height,
            ],
            suggestion: "Use ghost_find for AX-based element search, or ghost_ground to visually locate a specific element by description."
        )
    }

    // MARK: - ghost_ground

    /// Find precise screen coordinates for a described UI element using VLM.
    /// Takes a screenshot, sends it to the vision sidecar with the description,
    /// and returns the (x, y) coordinates where the element was found.
    public static func groundElement(
        description: String,
        appName: String?,
        cropBox: [Double]?
    ) -> ToolResult {
        // Check sidecar availability, try to start it if not running
        if !VisionBridge.isAvailable() {
            Log.info("Vision sidecar not running, attempting to start...")
            if !VisionBridge.startSidecar() {
                return sidecarUnavailableResult(tool: "ghost_ground")
            }
        }

        // Take screenshot (1280px width is ideal for VLM)
        guard let screenshot = captureForVision(appName: appName, fullResolution: false) else {
            return ToolResult(
                success: false,
                error: "Screenshot capture failed",
                suggestion: "Ensure Screen Recording permission is granted"
            )
        }

        // ── Coordinate mapping strategy ──
        //
        // Problem: SCK's desktopIndependentWindow captures the FULL Chrome window
        // (tabs, address bar, web content) but reports the frame of only the
        // content sub-window. The relationship between SCK frame and actual
        // captured area is unreliable for Chrome/Electron apps.
        //
        // Solution: Pass the MAIN DISPLAY logical dimensions as screen_w/screen_h.
        // For a maximized/fullscreen app, the screenshot covers essentially the
        // full display. The VLM normalizes coordinates to [0,1] relative to the
        // image, and multiplying by display dimensions gives screen-absolute
        // coordinates directly — no offset needed.
        //
        // This works because:
        // 1. Chrome in fullscreen covers the entire display
        // 2. VLM sees the screenshot as covering the full display area
        // 3. Normalized coords * display size = screen absolute coords
        //
        // For non-fullscreen windows, we fall back to window-relative mapping.

        let screenshotWidth = Double(screenshot.width)
        let screenshotHeight = Double(screenshot.height)
        let windowWidth = screenshot.windowWidth
        let windowHeight = screenshot.windowHeight
        let windowX = screenshot.windowX
        let windowY = screenshot.windowY

        // Get main display dimensions for fullscreen mapping
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayWidth = Double(mainScreen?.frame.width ?? 1728)
        let displayHeight = Double(mainScreen?.frame.height ?? 1117)

        // Determine if window is effectively fullscreen (covers most of display width)
        let isEffectivelyFullscreen = windowWidth > 0 && (windowWidth / displayWidth) > 0.9

        let sidecarWidth: Double
        let sidecarHeight: Double
        let offsetX: Double
        let offsetY: Double

        if isEffectivelyFullscreen {
            // Fullscreen: use display dimensions, no offset
            sidecarWidth = displayWidth
            sidecarHeight = displayHeight
            offsetX = 0
            offsetY = 0
        } else if windowWidth > 0 && windowHeight > 0 {
            // Non-fullscreen: use window dimensions + offset
            sidecarWidth = windowWidth
            sidecarHeight = windowHeight
            offsetX = windowX
            offsetY = windowY
        } else {
            // Fallback: use screenshot pixels
            sidecarWidth = screenshotWidth
            sidecarHeight = screenshotHeight
            offsetX = 0
            offsetY = 0
        }

        // Call VLM grounding
        guard let result = VisionBridge.ground(
            imageBase64: screenshot.base64PNG,
            description: description,
            screenWidth: sidecarWidth,
            screenHeight: sidecarHeight,
            cropBox: cropBox
        ) else {
            return ToolResult(
                success: false,
                error: "VLM grounding failed for '\(description)'",
                suggestion: "The vision sidecar may have crashed. Check its logs or restart it."
            )
        }

        // Map to screen-absolute coordinates
        let mappedX = result.x + offsetX
        let mappedY = result.y + offsetY
        Log.info("Vision ground: sidecar(\(Int(sidecarWidth))x\(Int(sidecarHeight))) → VLM (\(Int(result.x)),\(Int(result.y))) + offset (\(Int(offsetX)),\(Int(offsetY))) → screen (\(Int(mappedX)),\(Int(mappedY))) [fullscreen=\(isEffectivelyFullscreen)]")

        // Build response with screen-logical coordinates
        var data: [String: Any] = [
            "x": mappedX,
            "y": mappedY,
            "confidence": result.confidence,
            "method": result.method,
            "description": description,
            "inference_ms": result.inferenceMs,
            "screen_size": ["width": Int(screenshotWidth), "height": Int(screenshotHeight)],
            "window_frame": [
                "x": Int(windowX), "y": Int(windowY),
                "width": Int(windowWidth), "height": Int(windowHeight),
            ],
            "display_size": ["width": Int(displayWidth), "height": Int(displayHeight)],
            "vlm_raw": ["x": result.x, "y": result.y],
        ]

        if let cropBox, cropBox.count == 4 {
            data["crop_box"] = cropBox
        }

        // Include suggestion based on confidence
        var suggestion: String?
        if result.confidence < 0.3 {
            suggestion = "Low confidence (\(result.confidence)). The element may not be visible on screen. " +
                         "Try ghost_screenshot to verify, or use ghost_find for AX-based search."
        } else if result.confidence < 0.6 {
            suggestion = "Medium confidence. Consider using crop_box to narrow the search area for better accuracy."
        }

        return ToolResult(
            success: result.confidence > 0,
            data: data,
            suggestion: suggestion
        )
    }

    // MARK: - Vision-Enhanced Find (fallback for ghost_find)

    /// Try to find an element using VLM grounding as a fallback when AX search fails.
    /// Called by Perception.findElements when AX returns no results.
    ///
    /// Returns a synthetic element summary with VLM-grounded coordinates that can
    /// be used directly with ghost_click(x:, y:).
    public static func visionFallbackFind(
        query: String,
        appName: String?
    ) -> [[String: Any]]? {
        // Only try if sidecar is available (don't block on startup)
        guard VisionBridge.isAvailable() else {
            return nil
        }

        // Take screenshot
        guard let screenshot = captureForVision(appName: appName, fullResolution: false) else {
            return nil
        }

        // Use display dimensions for fullscreen apps, window dims otherwise
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayW = Double(mainScreen?.frame.width ?? 1728)
        let displayH = Double(mainScreen?.frame.height ?? 1117)
        let isFullscreen = screenshot.windowWidth > 0 && (screenshot.windowWidth / displayW) > 0.9

        let sidecarW: Double
        let sidecarH: Double
        let offX: Double
        let offY: Double
        if isFullscreen {
            sidecarW = displayW; sidecarH = displayH; offX = 0; offY = 0
        } else if screenshot.windowWidth > 0 {
            sidecarW = screenshot.windowWidth; sidecarH = screenshot.windowHeight
            offX = screenshot.windowX; offY = screenshot.windowY
        } else {
            sidecarW = Double(screenshot.width); sidecarH = Double(screenshot.height)
            offX = 0; offY = 0
        }

        // Run VLM grounding
        guard let result = VisionBridge.ground(
            imageBase64: screenshot.base64PNG,
            description: query,
            screenWidth: sidecarW,
            screenHeight: sidecarH
        ) else {
            return nil
        }

        // Only return if confidence is reasonable
        guard result.confidence >= 0.5 else {
            Log.info("Vision fallback for '\(query)': low confidence \(result.confidence), skipping")
            return nil
        }

        let mappedX = Int(result.x + offX)
        let mappedY = Int(result.y + offY)

        Log.info("Vision fallback found '\(query)' at screen (\(mappedX), \(mappedY)) conf=\(result.confidence)")

        // Return as a synthetic element summary matching ghost_find's output format
        let element: [String: Any] = [
            "name": query,
            "role": "VisionGrounded",
            "position": ["x": mappedX, "y": mappedY],
            "size": ["width": 40, "height": 40],  // Approximate click target
            "actionable": true,
            "grounded_by": "vlm",
            "confidence": result.confidence,
            "note": "Found by VLM vision grounding. Use ghost_click with x:\(mappedX) y:\(mappedY) to click.",
        ]

        return [element]
    }

    // MARK: - Vision-Enhanced Click (fallback for ghost_click)

    /// Try to click an element using VLM grounding as a fallback when AX can't find it.
    /// Called by Actions.click when AX-based click fails.
    ///
    /// Takes a screenshot, runs VLM grounding to find the element, then clicks
    /// at the grounded coordinates.
    public static func visionFallbackClick(
        query: String,
        appName: String?
    ) -> ToolResult? {
        // Only try if sidecar is available
        guard VisionBridge.isAvailable() else {
            return nil
        }

        // Take screenshot
        guard let screenshot = captureForVision(appName: appName, fullResolution: false) else {
            return nil
        }

        // Use display dimensions for fullscreen apps, window dims otherwise
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let displayW = Double(mainScreen?.frame.width ?? 1728)
        let displayH = Double(mainScreen?.frame.height ?? 1117)
        let isFullscreen = screenshot.windowWidth > 0 && (screenshot.windowWidth / displayW) > 0.9

        let sidecarW: Double
        let sidecarH: Double
        let offX: Double
        let offY: Double
        if isFullscreen {
            sidecarW = displayW; sidecarH = displayH; offX = 0; offY = 0
        } else if screenshot.windowWidth > 0 {
            sidecarW = screenshot.windowWidth; sidecarH = screenshot.windowHeight
            offX = screenshot.windowX; offY = screenshot.windowY
        } else {
            sidecarW = Double(screenshot.width); sidecarH = Double(screenshot.height)
            offX = 0; offY = 0
        }

        // Run VLM grounding
        guard let result = VisionBridge.ground(
            imageBase64: screenshot.base64PNG,
            description: query,
            screenWidth: sidecarW,
            screenHeight: sidecarH
        ) else {
            return nil
        }

        // Only click if confidence is reasonable
        guard result.confidence >= 0.5 else {
            Log.info("Vision click fallback for '\(query)': low confidence \(result.confidence)")
            return nil
        }

        let mappedX = result.x + offX
        let mappedY = result.y + offY

        Log.info("Vision click: '\(query)' at screen (\(Int(mappedX)), \(Int(mappedY))) conf=\(result.confidence)")

        return ToolResult(
            success: true,
            data: [
                "x": mappedX,
                "y": mappedY,
                "confidence": result.confidence,
                "method": "vlm-grounded",
                "description": query,
                "inference_ms": result.inferenceMs,
                "note": "Element found by VLM vision grounding. Use ghost_click(x:\(Int(mappedX)), y:\(Int(mappedY))) to click.",
            ],
            suggestion: "To click this element, use ghost_click with x:\(Int(mappedX)) y:\(Int(mappedY))"
        )
    }

    // MARK: - Private Helpers

    /// Capture a screenshot suitable for vision processing.
    /// Uses the existing ScreenCapture module (same as ghost_screenshot).
    private static func captureForVision(
        appName: String?,
        fullResolution: Bool
    ) -> ScreenshotResult? {
        let targetApp: NSRunningApplication
        if let appName {
            guard let app = Perception.findApp(named: appName) else {
                return nil
            }
            targetApp = app
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            targetApp = frontApp
        }

        return captureScreenshotSync(
            pid: targetApp.processIdentifier,
            fullResolution: fullResolution
        )
    }

    /// Synchronous screenshot capture (same pattern as Perception.swift).
    /// Bridge ScreenCaptureKit async to sync using RunLoop spinning.
    private static var isCapturing = false

    private static func captureScreenshotSync(
        pid: pid_t,
        fullResolution: Bool
    ) -> ScreenshotResult? {
        guard ScreenCapture.hasPermission() else {
            Log.error("Vision: Screen Recording permission not granted")
            return nil
        }

        guard !isCapturing else {
            Log.warn("Vision: capture already in-flight")
            return nil
        }
        isCapturing = true
        defer { isCapturing = false }

        var result: ScreenshotResult?
        var completed = false

        Task { @MainActor in
            result = await ScreenCapture.captureWindow(
                pid: pid, fullResolution: fullResolution
            )
            completed = true
        }

        let deadline = Date().addingTimeInterval(10)
        while !completed && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        if !completed {
            Log.error("Vision: screenshot timed out")
        }

        return result
    }

    /// Standard error result when the vision sidecar is not available.
    private static func sidecarUnavailableResult(tool: String) -> ToolResult {
        ToolResult(
            success: false,
            error: "Vision sidecar not running. \(tool) requires the Python vision sidecar.",
            suggestion: "Start the sidecar: cd ghost-os-v2/vision-sidecar && python3 server.py &\n" +
                        "Or use ghost_find for AX-based element search (works without sidecar)."
        )
    }
}
