// BehavioralMimicry.swift - Human-like mouse and interaction patterns for Ghost OS
//
// Bot detection systems analyze behavioral patterns beyond timing:
// - Mouse teleportation (instant jump to target) vs smooth cursor movement
// - Perfectly straight mouse paths vs natural curves
// - Clicking exact center of buttons vs slightly off-center
// - No scrolling/hovering before action vs natural reading behavior
//
// BehavioralMimicry provides realistic interaction patterns that mimic
// human motor control. Uses cubic Bezier curves for mouse paths (matching
// how human wrist/arm movement naturally creates smooth arcs).

import CoreGraphics
import Foundation

/// Human-like behavioral patterns for mouse and interaction mimicry.
public enum BehavioralMimicry {

    // MARK: - Mouse Path Generation

    /// Generate a natural-looking mouse path from one point to another.
    ///
    /// Uses a cubic Bezier curve with randomized control points to simulate
    /// the natural arc of human wrist/arm movement. Real mouse paths are
    /// never perfectly straight — they curve slightly due to arm mechanics.
    ///
    /// - Parameters:
    ///   - from: Starting point.
    ///   - to: Target point.
    ///   - steps: Number of intermediate points (default 10).
    /// - Returns: Array of points along the curve, including start and end.
    public static func mousePath(from: CGPoint, to: CGPoint, steps: Int = 10) -> [CGPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y

        // Control points create a slight arc (not a straight line)
        // Randomize to avoid detectable patterns across multiple moves
        let control1 = CGPoint(
            x: from.x + dx * 0.25 + CGFloat.random(in: -30...30),
            y: from.y + dy * 0.1 + CGFloat.random(in: -20...20)
        )
        let control2 = CGPoint(
            x: from.x + dx * 0.75 + CGFloat.random(in: -20...20),
            y: from.y + dy * 0.9 + CGFloat.random(in: -10...10)
        )

        return cubicBezier(p0: from, p1: control1, p2: control2, p3: to, steps: steps)
    }

    /// Generate a short, jittery mouse path for nearby targets.
    ///
    /// When the mouse only needs to move a short distance (<50px), humans
    /// make quick, slightly wobbly movements rather than smooth arcs.
    ///
    /// - Parameters:
    ///   - from: Starting point.
    ///   - to: Target point.
    /// - Returns: 3-5 points with micro-jitter.
    public static func shortMousePath(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let distance = hypot(to.x - from.x, to.y - from.y)
        if distance < 5 {
            return [from, to]  // Too close, just jump
        }

        let steps = min(5, max(3, Int(distance / 15)))
        var points: [CGPoint] = [from]

        for i in 1..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = from.x + (to.x - from.x) * t + CGFloat.random(in: -1.5...1.5)
            let y = from.y + (to.y - from.y) * t + CGFloat.random(in: -1.5...1.5)
            points.append(CGPoint(x: x, y: y))
        }

        points.append(to)
        return points
    }

    // MARK: - Scroll Behavior

    /// Determine if a pre-action scroll should be simulated.
    ///
    /// Humans often scroll slightly before clicking — they're reading the page,
    /// scanning for the target, or adjusting their view. This is a strong
    /// behavioral signal that distinguishes humans from bots.
    ///
    /// - Returns: A scroll amount (0 = no scroll, 1-3 = small scroll lines).
    public static func preActionScrollAmount() -> Int {
        // 25% chance of a small pre-action scroll
        if Int.random(in: 0..<4) == 0 {
            return Int.random(in: 1...3)
        }
        return 0
    }

    /// Determine scroll direction based on target position.
    ///
    /// If the target is in the lower third of the viewport, humans tend to
    /// scroll down slightly first (reading behavior). Upper third → no scroll.
    ///
    /// - Parameter targetY: The Y coordinate of the target on screen.
    /// - Parameter screenHeight: The visible screen height.
    /// - Returns: "down", "up", or nil (no scroll).
    public static func scrollDirection(targetY: Double, screenHeight: Double) -> String? {
        let ratio = targetY / screenHeight
        if ratio > 0.7 {
            return Int.random(in: 0..<3) == 0 ? "down" : nil  // 33% chance
        } else if ratio < 0.2 {
            return Int.random(in: 0..<5) == 0 ? "up" : nil    // 20% chance
        }
        return nil
    }

    // MARK: - Click Offset

    /// Generate a human-like click offset within a button's bounds.
    ///
    /// Humans don't click the exact mathematical center of buttons.
    /// They click slightly off-center, biased towards the text/icon.
    /// The offset is proportional to the element size (bigger = more variance).
    ///
    /// - Parameters:
    ///   - center: The element's center point.
    ///   - width: The element's width.
    ///   - height: The element's height.
    /// - Returns: A slightly offset click point.
    public static func clickOffset(
        center: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) -> CGPoint {
        // Max offset: 15% of dimension, but at least 1px and at most 5px
        let maxOffX = max(1.0, min(5.0, width * 0.15))
        let maxOffY = max(1.0, min(3.0, height * 0.15))

        return CGPoint(
            x: center.x + CGFloat.random(in: -maxOffX...maxOffX),
            y: center.y + CGFloat.random(in: -maxOffY...maxOffY)
        )
    }

    // MARK: - Private: Bezier Math

    /// Compute a point on a cubic Bezier curve at parameter t.
    private static func cubicBezierPoint(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat
    ) -> CGPoint {
        let mt = 1.0 - t
        let mt2 = mt * mt
        let mt3 = mt2 * mt
        let t2 = t * t
        let t3 = t2 * t

        return CGPoint(
            x: mt3 * p0.x + 3 * mt2 * t * p1.x + 3 * mt * t2 * p2.x + t3 * p3.x,
            y: mt3 * p0.y + 3 * mt2 * t * p1.y + 3 * mt * t2 * p2.y + t3 * p3.y
        )
    }

    /// Generate points along a cubic Bezier curve.
    private static func cubicBezier(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, steps: Int
    ) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            points.append(cubicBezierPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
        }
        return points
    }
}
