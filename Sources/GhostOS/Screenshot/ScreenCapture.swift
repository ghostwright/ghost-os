// ScreenCapture.swift - Window screenshot capture
//
// Two capture paths:
//   1. captureWindowSync() — CGWindowListCreateImage (synchronous, preferred)
//   2. captureWindow()     — ScreenCaptureKit (async, kept for reference)
//
// The sync path is used by the MCP server. The async SCK path broke on
// macOS 26 because Swift 6.2's main actor executor no longer reliably
// dispatches Task continuations through RunLoop.main.run(until:).
// CGWindowListCreateImage is fully synchronous and avoids this entirely.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures screenshots of specific windows.
public enum ScreenCapture {

    /// Check if Screen Recording permission is granted.
    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission (shows system dialog).
    public static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Synchronous Capture (CGWindowListCreateImage)

    /// Failure reasons returned alongside a nil ScreenshotResult so callers
    /// can produce specific error messages instead of a generic "capture failed".
    public enum CaptureFailure: Sendable {
        case noPermission
        case windowListUnavailable
        case noWindowsForApp
        case captureReturnedNil(windowID: CGWindowID)
        case imageTooSmall(width: Int, height: Int)
    }

    /// Capture a window synchronously using CoreGraphics.
    ///
    /// Uses CGWindowListCreateImage which is fully synchronous — no async,
    /// no RunLoop spinning, no Task bridging. Works reliably on all macOS
    /// versions including macOS 26 developer beta.
    ///
    /// - Parameters:
    ///   - pid: Process ID of the target application.
    ///   - fullResolution: If true, capture at Retina resolution. Otherwise 1280px max width.
    /// - Returns: Screenshot result with base64 PNG, or nil if capture failed.
    public static func captureWindowSync(
        pid: pid_t,
        fullResolution: Bool = false
    ) -> ScreenshotResult? {
        let (result, _) = captureWindowSyncWithReason(pid: pid, fullResolution: fullResolution)
        return result
    }

    /// Capture a window synchronously, returning both the result and a failure
    /// reason when nil. This lets callers produce targeted error messages.
    public static func captureWindowSyncWithReason(
        pid: pid_t,
        fullResolution: Bool = false
    ) -> (ScreenshotResult?, CaptureFailure?) {
        guard hasPermission() else {
            Log.error("Screenshot: Screen Recording permission not granted")
            return (nil, .noPermission)
        }

        // Get ALL windows from CoreGraphics — not just on-screen ones.
        // .optionAll (value 0) lists every window in the system, including
        // minimized windows, windows behind other windows, and windows in
        // other Spaces. CGWindowListCreateImage(.null, .optionIncludingWindow, ...)
        // can capture these by window ID even when they are not on-screen.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            Log.error("Screenshot: CGWindowListCopyWindowInfo returned nil")
            return (nil, .windowListUnavailable)
        }

        // Find windows belonging to the target PID.
        var candidates = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid
            else { return false }
            // Normal window layer only (skip menubars, system overlays, etc.)
            let layer = info[kCGWindowLayer] as? Int ?? -1
            guard layer == 0 else { return false }
            // Must have a reasonable size
            if let bounds = info[kCGWindowBounds] as? [String: Any],
               let w = bounds["Width"] as? CGFloat,
               let h = bounds["Height"] as? CGFloat
            {
                return w > 50 && h > 50
            }
            return false
        }

        // Fallback: Chrome/Electron helper processes may own windows under
        // a different PID than NSWorkspace reports. Match by owner name.
        if candidates.isEmpty {
            let targetApp = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier == pid
            }
            if let targetName = targetApp?.localizedName {
                candidates = windowList.filter { info in
                    guard let ownerName = info[kCGWindowOwnerName] as? String,
                          ownerName == targetName
                    else { return false }
                    let layer = info[kCGWindowLayer] as? Int ?? -1
                    guard layer == 0 else { return false }
                    if let bounds = info[kCGWindowBounds] as? [String: Any],
                       let w = bounds["Width"] as? CGFloat,
                       let h = bounds["Height"] as? CGFloat
                    {
                        return w > 50 && h > 50
                    }
                    return false
                }
                Log.debug("Screenshot: owner name '\(targetName)' matched \(candidates.count) windows")
            }
        }

        guard !candidates.isEmpty else {
            Log.warn("Screenshot: no suitable window found for PID \(pid)")
            return (nil, .noWindowsForApp)
        }

        // Pick the largest window by area.
        let bestWindow = candidates.max { a, b in
            windowArea(a) < windowArea(b)
        } ?? candidates[0]

        guard let windowID = bestWindow[kCGWindowNumber] as? CGWindowID else {
            Log.error("Screenshot: window has no CGWindowID")
            return (nil, .noWindowsForApp)
        }

        let windowTitle = bestWindow[kCGWindowName] as? String
        let bounds = bestWindow[kCGWindowBounds] as? [String: Any]
        let windowX = bounds?["X"] as? Double ?? 0
        let windowY = bounds?["Y"] as? Double ?? 0
        let windowWidth = bounds?["Width"] as? Double ?? 0
        let windowHeight = bounds?["Height"] as? Double ?? 0

        Log.info("Screenshot: capturing windowID=\(windowID) title=\(windowTitle ?? "<none>") frame=(\(Int(windowX)),\(Int(windowY)),\(Int(windowWidth)),\(Int(windowHeight)))")

        // CGWindowListCreateImage: fully synchronous capture.
        // .bestResolution = Retina pixels; .nominalResolution = logical points.
        let imageOption: CGWindowImageOption = fullResolution
            ? [.bestResolution, .boundsIgnoreFraming]
            : [.nominalResolution, .boundsIgnoreFraming]

        guard let cgImage = CGWindowListCreateImage(
            .null,                          // .null = use the window's own bounds
            .optionIncludingWindow,         // capture only this specific window
            windowID,
            imageOption
        ) else {
            Log.error("Screenshot: CGWindowListCreateImage returned nil for windowID \(windowID)")
            return (nil, .captureReturnedNil(windowID: windowID))
        }

        // Off-screen windows (minimized, other Space) may return a tiny or blank
        // image. Treat anything smaller than 10x10 as a failed capture so the
        // caller can activate the app and retry.
        if cgImage.width < 10 || cgImage.height < 10 {
            Log.warn("Screenshot: captured image too small (\(cgImage.width)x\(cgImage.height)) — window may be minimized or off-screen")
            return (nil, .imageTooSmall(width: cgImage.width, height: cgImage.height))
        }

        // Downscale if needed (non-fullResolution with wide images)
        let finalImage: CGImage
        if !fullResolution && cgImage.width > 1280 {
            finalImage = downsample(cgImage, maxWidth: 1280)
        } else {
            finalImage = cgImage
        }

        // Convert to PNG
        let bitmap = NSBitmapImageRep(cgImage: finalImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Log.error("Screenshot: PNG encoding failed")
            return (nil, .captureReturnedNil(windowID: windowID))
        }

        return (ScreenshotResult(
            base64PNG: pngData.base64EncodedString(),
            width: finalImage.width,
            height: finalImage.height,
            windowTitle: windowTitle,
            mimeType: "image/png",
            windowX: windowX,
            windowY: windowY,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        ), nil)
    }

    // MARK: - Helpers

    /// Calculate window area from a CG window info dictionary.
    private static func windowArea(_ info: [CFString: Any]) -> Double {
        guard let bounds = info[kCGWindowBounds] as? [String: Any],
              let w = bounds["Width"] as? Double,
              let h = bounds["Height"] as? Double
        else { return 0 }
        return w * h
    }

    /// Downsample a CGImage to fit within maxWidth, preserving aspect ratio.
    private static func downsample(_ image: CGImage, maxWidth: Int) -> CGImage {
        let aspect = Double(image.height) / Double(image.width)
        let newWidth = maxWidth
        let newHeight = Int(Double(maxWidth) * aspect)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    // MARK: - Async Capture (ScreenCaptureKit) — Legacy

    /// Capture a specific window as a PNG image using ScreenCaptureKit.
    ///
    /// NOTE: This async method is kept for reference but is NOT used by the
    /// MCP server. The sync path (captureWindowSync) is preferred because
    /// bridging this async API back to sync broke on macOS 26.
    public static func captureWindow(
        pid: pid_t,
        windowTitle: String? = nil,
        fullResolution: Bool = false
    ) async -> ScreenshotResult? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            Log.error("Screenshot: failed to get shareable content: \(error)")
            return nil
        }

        // Primary: filter windows by PID
        var candidateWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        Log.debug("Screenshot: PID \(pid) matched \(candidateWindows.count) windows")

        // Fallback: if PID matching found nothing, try matching by bundle identifier.
        if candidateWindows.isEmpty {
            let targetApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
            if let bundleId = targetApp?.bundleIdentifier {
                candidateWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bundleId
                }
                Log.debug("Screenshot: bundle \(bundleId) matched \(candidateWindows.count) windows")
            }
        }

        let window: SCWindow?
        if let title = windowTitle {
            window = candidateWindows.first { $0.title?.localizedCaseInsensitiveContains(title) == true }
        } else {
            window = candidateWindows
                .filter { $0.frame.width > 100 && $0.frame.height > 100 }
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        }

        guard let window else {
            Log.warn("Screenshot: no suitable window found for PID \(pid) (\(candidateWindows.count) candidates)")
            return nil
        }

        let config = SCStreamConfiguration()
        config.showsCursor = false

        if fullResolution {
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
        } else {
            let maxWidth = 1280
            let aspect = window.frame.height / window.frame.width
            let captureWidth = min(maxWidth, Int(window.frame.width))
            config.width = captureWidth
            config.height = Int(CGFloat(captureWidth) * aspect)
        }
        config.scalesToFit = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            Log.error("Screenshot: capture failed: \(error)")
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        return ScreenshotResult(
            base64PNG: pngData.base64EncodedString(),
            width: cgImage.width,
            height: cgImage.height,
            windowTitle: window.title,
            mimeType: "image/png",
            windowX: Double(window.frame.origin.x),
            windowY: Double(window.frame.origin.y),
            windowWidth: Double(window.frame.width),
            windowHeight: Double(window.frame.height)
        )
    }
}
