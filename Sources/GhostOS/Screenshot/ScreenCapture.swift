// ScreenCapture.swift - Window screenshot capture via ScreenCaptureKit
//
// Carried forward from v1 nearly as-is. Works on background windows.
// Requires Screen Recording permission.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures screenshots of specific windows using ScreenCaptureKit.
/// Resizes to max 1280px width to keep base64 payload reasonable.
/// Pass fullResolution: true for native resolution (reading small text).
public enum ScreenCapture {

    /// Check if Screen Recording permission is granted.
    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission (shows system dialog).
    public static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Capture a specific window as a PNG image.
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

        let pidWindows = content.windows.filter { $0.owningApplication?.processID == pid }

        let window: SCWindow?
        if let title = windowTitle {
            window = pidWindows.first { $0.title?.localizedCaseInsensitiveContains(title) == true }
        } else {
            window = pidWindows
                .filter { $0.frame.width > 100 && $0.frame.height > 100 }
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        }
        guard let window else { return nil }

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
        // scalesToFit tells ScreenCaptureKit to fit the capture into the
        // requested dimensions. Without it, dimension mismatches between
        // points and pixels (Retina displays) can crash.
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

        // PNG is safe for all CGImage formats (including alpha channel from
        // ScreenCaptureKit). JPEG can crash on RGBA images. v1 used PNG and
        // it worked reliably. Size is managed by the 1280px downscale.
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let mimeType = "image/png"

        return ScreenshotResult(
            base64PNG: pngData.base64EncodedString(),
            width: cgImage.width,
            height: cgImage.height,
            windowTitle: window.title,
            mimeType: mimeType
        )
    }
}
