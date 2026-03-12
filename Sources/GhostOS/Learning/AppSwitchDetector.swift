// AppSwitchDetector.swift - Detects app switches during learning
//
// Polls NSWorkspace.shared.frontmostApplication on each event.
// When the frontmost app differs from the last recorded app,
// injects an appSwitch action into the recording.
// This detects Cmd+Tab, three-finger swipe, Dock clicks, etc.
// CGEvent tap alone cannot capture these -- polling is required.

import AppKit
import Foundation

nonisolated enum AppSwitchDetector {

    /// Check if the frontmost app changed. If so, record an appSwitch action.
    /// Returns true if a switch was detected.
    @discardableResult
    static func checkAndRecord(
        recorder: LearningRecorder,
        lastRecordedApp: inout String
    ) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let name = frontApp.localizedName else {
            return false
        }

        // Skip the first call (initial app detection, not a user-initiated switch)
        guard name != lastRecordedApp, !lastRecordedApp.isEmpty else {
            if lastRecordedApp.isEmpty {
                lastRecordedApp = name
            }
            return false
        }

        let bundleId = frontApp.bundleIdentifier ?? ""
        let previousApp = lastRecordedApp
        lastRecordedApp = name

        // Flush pending coalesced events from the previous app
        recorder.flushPendingKeystrokesOnLearningThread()
        recorder.flushPendingScrollOnLearningThread()

        recorder.appendAction(ObservedAction(
            timestamp: mach_absolute_time(),
            action: .appSwitch(toApp: name, toBundleId: bundleId),
            appName: previousApp,
            appBundleId: "",
            windowTitle: nil,
            url: nil,
            elementContext: nil
        ))

        learningLog("DEBUG", "Learning: app switch detected \(previousApp) -> \(name)")
        return true
    }
}
