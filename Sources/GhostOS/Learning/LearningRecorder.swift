// LearningRecorder.swift - CGEvent tap lifecycle and action recording
//
// Owns the background thread, CGEvent tap, and thread-safe action buffer.
// All methods are nonisolated because this class manages its own thread safety
// via os_unfair_lock. Uses learningLog() instead of Log because Log inherits
// MainActor from the package default and cannot be called from background threads.

import ApplicationServices
import AppKit
import Foundation

/// Records user input events during learning mode.
/// Thread-safe via os_unfair_lock. Accessed from both the main thread
/// (MCP dispatch) and the learning thread (CGEvent callback).
nonisolated public final class LearningRecorder: @unchecked Sendable {

    public static let shared = LearningRecorder()

    // MARK: - Lock-protected state

    private var lock = os_unfair_lock()
    private var session: LearningSession?
    private var eventTap: CFMachPort?
    private var learningRunLoop: CFRunLoop?
    private var learningThread: Thread?
    private var startupCancelled = false

    // Keystroke coalescing -- only access within withLock or flushPending* (caller holds lock)
    internal var pendingKeystrokes: String = ""
    internal var pendingKeystrokeTimestamp: UInt64 = 0
    internal var pendingKeystrokeApp: String = ""
    internal var pendingKeystrokeBundleId: String = ""
    internal var pendingKeystrokeWindow: String?
    internal var pendingKeystrokeUrl: String?
    internal var pendingKeystrokeElement: ElementContext?
    private var keystrokeFlushTimer: CFRunLoopTimer?

    // Max duration safety timer
    private var maxDurationTimer: CFRunLoopTimer?

    // Scroll coalescing -- only access within withLock or flushPending* (caller holds lock)
    internal var pendingScrollDeltaX: Int = 0
    internal var pendingScrollDeltaY: Int = 0
    internal var pendingScrollX: Double = 0
    internal var pendingScrollY: Double = 0
    internal var pendingScrollTimestamp: UInt64 = 0
    internal var pendingScrollApp: String = ""
    internal var pendingScrollBundleId: String = ""
    private var scrollFlushTimer: CFRunLoopTimer?

    private var lastRecordedAppName: String = ""

    private init() {}

    // MARK: - Public API

    public var isRecording: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return session != nil
    }

    /// Start recording. Returns nil on success, or a LearningError.
    public func start(taskDescription: String?) -> LearningError? {
        os_unfair_lock_lock(&lock)
        if session != nil { os_unfair_lock_unlock(&lock); return .alreadyRecording }
        session = LearningSession(taskDescription: taskDescription)
        lastRecordedAppName = ""
        startupCancelled = false
        os_unfair_lock_unlock(&lock)

        let startupSignal = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in self?.runLearningThread(startupSignal: startupSignal) }
        thread.name = "ghost-learning"
        thread.qualityOfService = .userInteractive
        learningThread = thread
        thread.start()

        let signaled = startupSignal.wait(timeout: .now() + .milliseconds(500)) == .success

        os_unfair_lock_lock(&lock)
        let failed = !signaled || eventTap == nil
        if failed {
            session = nil
            startupCancelled = true
        }
        os_unfair_lock_unlock(&lock)

        if failed {
            for _ in 0..<50 {
                if learningThread?.isFinished == true { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if learningThread?.isFinished == true {
                learningThread = nil
                learningRunLoop = nil
            }
        }
        if !failed { learningLog("INFO", "Learning: recording started") }
        return failed ? .inputMonitoringNotGranted : nil
    }

    /// Stop recording and return the session with its recorded actions.
    public func stop() -> Result<(LearningSession, [ObservedAction]), LearningError> {
        os_unfair_lock_lock(&lock)
        guard var cur = session else { os_unfair_lock_unlock(&lock); return .failure(.notRecording) }
        flushPendingKeystrokes(into: &cur)
        flushPendingScroll(into: &cur)
        let actions = cur.actions
        let result = cur
        session = nil
        startupCancelled = false
        os_unfair_lock_unlock(&lock)

        if let rl = learningRunLoop { CFRunLoopStop(rl) }
        for _ in 0..<200 {
            if learningThread?.isFinished == true { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        learningThread = nil; learningRunLoop = nil

        if actions.isEmpty { return .failure(.noActionsRecorded) }
        learningLog("INFO", "Learning: stopped, recorded \(actions.count) actions")
        return .success((result, actions))
    }

    public func status() -> (isRecording: Bool, actionCount: Int, durationSeconds: Double, currentApp: String?) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let session else { return (false, 0, 0, nil) }
        let duration = Date().timeIntervalSince(session.startTime)
        return (true, session.actions.count, duration, lastRecordedAppName.isEmpty ? nil : lastRecordedAppName)
    }

    // MARK: - Background Thread

    private func runLearningThread(startupSignal: DispatchSemaphore) {
        os_unfair_lock_lock(&lock)
        let cancelledBeforeStart = startupCancelled || session == nil
        os_unfair_lock_unlock(&lock)
        if cancelledBeforeStart {
            startupSignal.signal()
            return
        }

        var mask: CGEventMask = 0
        for t: CGEventType in [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel] {
            mask |= (1 << t.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: learningEventCallback, userInfo: userInfo
        ) else {
            learningLog("ERROR", "Learning: CGEvent tap creation failed (Input Monitoring not granted?)")
            os_unfair_lock_lock(&lock)
            session = nil
            startupCancelled = true
            os_unfair_lock_unlock(&lock)
            startupSignal.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let rl = CFRunLoopGetCurrent()!
        os_unfair_lock_lock(&lock)
        let cancelledAfterCreate = startupCancelled || session == nil
        if !cancelledAfterCreate {
            eventTap = tap
            learningRunLoop = rl
        }
        os_unfair_lock_unlock(&lock)
        startupSignal.signal()
        if cancelledAfterCreate { return }

        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Safety timer: auto-stop after max recording duration to prevent runaway recordings
        let maxFire = CFAbsoluteTimeGetCurrent() + LearningConstants.maxRecordingDurationSeconds
        let maxTimer = CFRunLoopTimerCreateWithHandler(nil, maxFire, 0, 0, 0) { _ in
            learningLog("WARN", "Learning: max recording duration reached (\(Int(LearningConstants.maxRecordingDurationSeconds))s), stopping event tap")
            // Stop the run loop but preserve the session so stop() can harvest the data
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopAddTimer(rl, maxTimer, .commonModes)
        os_unfair_lock_lock(&lock); maxDurationTimer = maxTimer; os_unfair_lock_unlock(&lock)

        learningLog("INFO", "Learning: CGEvent tap started on background thread")
        CFRunLoopRun()

        // Cleanup
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(rl, source, .commonModes)
        os_unfair_lock_lock(&lock)
        eventTap = nil
        learningRunLoop = nil
        learningThread = nil
        startupCancelled = false
        invalidateTimer(&keystrokeFlushTimer)
        invalidateTimer(&scrollFlushTimer)
        invalidateTimer(&maxDurationTimer)
        os_unfair_lock_unlock(&lock)
        learningLog("INFO", "Learning: CGEvent tap stopped, thread exiting")
    }

    private func invalidateTimer(_ timer: inout CFRunLoopTimer?) {
        if let t = timer { CFRunLoopTimerInvalidate(t); timer = nil }
    }

    // MARK: - Event Handling (learning thread)

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            os_unfair_lock_lock(&lock)
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            os_unfair_lock_unlock(&lock)
            learningLog("WARN", "Learning: event tap re-enabled after system disabled it")
            return
        }
        os_unfair_lock_lock(&lock)
        guard session != nil else { os_unfair_lock_unlock(&lock); return }
        var localLastApp = lastRecordedAppName
        os_unfair_lock_unlock(&lock)

        AppSwitchDetector.checkAndRecord(recorder: self, lastRecordedApp: &localLastApp)

        os_unfair_lock_lock(&lock)
        lastRecordedAppName = localLastApp
        os_unfair_lock_unlock(&lock)

        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           LearningConstants.restrictedBundleIds.contains(bid) { return }

        switch type {
        case .keyDown: EventHandlers.handleKeyDown(event, recorder: self)
        case .leftMouseDown, .rightMouseDown: EventHandlers.handleMouseDown(type, event, recorder: self)
        case .scrollWheel: EventHandlers.handleScroll(event, recorder: self)
        default: break
        }
    }

    // MARK: - Action Recording

    internal func appendAction(_ action: ObservedAction) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        session?.actions.append(action)
        if !action.appName.isEmpty { session?.apps.insert(action.appName) }
        if let url = action.url, !url.isEmpty, !(session?.urls.contains(url) ?? false) {
            session?.urls.append(url)
        }
    }

    // MARK: - Keystroke Coalescing

    /// Flush pending keystrokes into a typeText action. Caller must hold the lock.
    internal func flushPendingKeystrokes(into session: inout LearningSession) {
        guard !pendingKeystrokes.isEmpty else { return }
        session.actions.append(ObservedAction(
            timestamp: pendingKeystrokeTimestamp,
            action: .typeText(text: pendingKeystrokes),
            appName: pendingKeystrokeApp, appBundleId: pendingKeystrokeBundleId,
            windowTitle: pendingKeystrokeWindow, url: pendingKeystrokeUrl,
            elementContext: pendingKeystrokeElement
        ))
        pendingKeystrokes = ""; pendingKeystrokeElement = nil
        invalidateTimer(&keystrokeFlushTimer)
    }

    internal func flushPendingKeystrokesOnLearningThread() {
        os_unfair_lock_lock(&lock)
        guard var s = session else { os_unfair_lock_unlock(&lock); return }
        flushPendingKeystrokes(into: &s); session = s
        os_unfair_lock_unlock(&lock)
    }

    internal func scheduleKeystrokeFlushTimer() {
        os_unfair_lock_lock(&lock)
        invalidateTimer(&keystrokeFlushTimer)
        let fire = CFAbsoluteTimeGetCurrent() + LearningConstants.keystrokeFlushTimeoutSeconds
        let t = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { [weak self] _ in
            self?.flushPendingKeystrokesOnLearningThread()
        }
        keystrokeFlushTimer = t
        if let rl = learningRunLoop { CFRunLoopAddTimer(rl, t, .commonModes) }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Scroll Coalescing

    /// Flush pending scroll into a single scroll action. Caller must hold the lock.
    internal func flushPendingScroll(into session: inout LearningSession) {
        guard pendingScrollDeltaX != 0 || pendingScrollDeltaY != 0 else { return }
        session.actions.append(ObservedAction(
            timestamp: pendingScrollTimestamp,
            action: .scroll(deltaX: pendingScrollDeltaX, deltaY: pendingScrollDeltaY,
                           x: pendingScrollX, y: pendingScrollY),
            appName: pendingScrollApp, appBundleId: pendingScrollBundleId,
            windowTitle: nil, url: nil, elementContext: nil
        ))
        pendingScrollDeltaX = 0; pendingScrollDeltaY = 0
        invalidateTimer(&scrollFlushTimer)
    }

    internal func flushPendingScrollOnLearningThread() {
        os_unfair_lock_lock(&lock)
        guard var s = session else { os_unfair_lock_unlock(&lock); return }
        flushPendingScroll(into: &s); session = s
        os_unfair_lock_unlock(&lock)
    }

    internal func scheduleScrollFlushTimer() {
        os_unfair_lock_lock(&lock)
        invalidateTimer(&scrollFlushTimer)
        let fire = CFAbsoluteTimeGetCurrent() + LearningConstants.scrollFlushTimeoutSeconds
        let t = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { [weak self] _ in
            self?.flushPendingScrollOnLearningThread()
        }
        scrollFlushTimer = t
        if let rl = learningRunLoop { CFRunLoopAddTimer(rl, t, .commonModes) }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Lock API

    internal func withLock<T>(_ body: (inout LearningSession?) -> T) -> T {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return body(&session)
    }
}

// MARK: - C Callback

private nonisolated func learningEventCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<LearningRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handleEvent(type, event)
    return Unmanaged.passUnretained(event)
}
