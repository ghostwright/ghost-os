// TimingJitter.swift - Human-like timing randomization for Ghost OS
//
// Anti-bot detection relies on timing patterns. Bots are predictable:
// fixed delays between actions, instant mouse teleportation, uniform
// typing speed. Humans are noisy: variable delays, hesitations, bursts.
//
// TimingJitter provides log-normal distributed delays that mimic human
// reaction times. Log-normal is used because human response times are
// right-skewed: mostly quick, occasionally slow (distracted/thinking).
//
// Usage:
//   let delay = TimingJitter.humanDelay(base: 0.5)  // ~0.2-1.5s
//   let typeDelay = TimingJitter.typingDelay()       // ~50-150ms per char
//   let point = TimingJitter.jitter(point, radius: 2) // ±2px

import CoreGraphics
import Foundation

/// Human-like timing randomization to avoid bot detection.
public enum TimingJitter {

    // MARK: - Action Delays

    /// Generate a human-like delay between actions.
    ///
    /// Uses log-normal distribution centered around `base` seconds.
    /// Log-normal models human reaction times: mostly quick, occasionally slow.
    ///
    /// - Parameter base: The median delay in seconds (default 0.5s).
    /// - Returns: A randomized delay in seconds, typically 0.3x-3x of base.
    public static func humanDelay(base: TimeInterval = 0.5) -> TimeInterval {
        let mu = log(base)
        let sigma = 0.4
        // Box-Muller transform for normal distribution
        let u1 = Double.random(in: 0.001...1.0)
        let u2 = Double.random(in: 0.0...1.0)
        let normal = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        // Clamp to avoid extreme outliers
        let clamped = max(-2.5, min(2.5, normal))
        let result = exp(mu + sigma * clamped)
        // Floor at 50ms, ceiling at 5s
        return max(0.05, min(5.0, result))
    }

    /// Generate a human-like typing delay per character.
    ///
    /// Average human typing speed: 40-80 WPM (75-150ms per character).
    /// Fast typists: 80-120 WPM (50-75ms). Hunts-and-pecks: 20-40 WPM (150-300ms).
    ///
    /// - Returns: Delay in seconds for one keystroke.
    public static func typingDelay() -> TimeInterval {
        // Normal range centered at 100ms with 30ms std dev
        let base = 0.1
        let jitter = Double.random(in: -0.05...0.05)
        let result = base + jitter
        return max(0.03, min(0.25, result))
    }

    /// Generate a burst typing pattern: fast sequences with occasional pauses.
    ///
    /// Humans type in bursts of 3-8 characters, then pause briefly (word boundary,
    /// thinking, looking at keyboard). This is more realistic than uniform timing.
    ///
    /// - Parameter charIndex: The index of the current character in the string.
    /// - Returns: Delay in seconds before this keystroke.
    public static func burstTypingDelay(charIndex: Int) -> TimeInterval {
        // Every 3-8 chars, insert a longer "thinking" pause
        let burstLength = Int.random(in: 3...8)
        if charIndex > 0 && charIndex % burstLength == 0 {
            return humanDelay(base: 0.3)  // Word boundary pause
        }
        return typingDelay()
    }

    // MARK: - Coordinate Jitter

    /// Add random noise to click coordinates.
    ///
    /// Humans don't click at exact pixel coordinates. There's always a few
    /// pixels of noise from hand tremor and mouse precision.
    ///
    /// - Parameters:
    ///   - point: The target click point.
    ///   - radius: Maximum jitter in pixels (default ±2px).
    /// - Returns: A slightly randomized point within the jitter radius.
    public static func jitter(_ point: CGPoint, radius: CGFloat = 2.0) -> CGPoint {
        CGPoint(
            x: point.x + CGFloat.random(in: -radius...radius),
            y: point.y + CGFloat.random(in: -radius...radius)
        )
    }

    // MARK: - Pre/Post Action Delays

    /// Delay before clicking (human reads/aims at target).
    public static func preClickDelay() -> TimeInterval {
        humanDelay(base: 0.3)
    }

    /// Delay after clicking (human waits for visual feedback).
    public static func postClickDelay() -> TimeInterval {
        humanDelay(base: 0.5)
    }

    /// Delay before typing starts (human focuses on input field).
    public static func preTypeDelay() -> TimeInterval {
        humanDelay(base: 0.2)
    }
}
