// StealthTests.swift - Unit tests for TimingJitter and BehavioralMimicry

import CoreGraphics
import Testing
@testable import GhostOS

@Suite("Stealth Tests")
struct StealthTests {

    // MARK: - TimingJitter

    @Test("Human delay produces bounded values")
    func humanDelayBounds() {
        for _ in 0..<100 {
            let delay = TimingJitter.humanDelay(base: 0.5)
            #expect(delay >= 0.05, "Delay should be at least 50ms, got \(delay)")
            #expect(delay <= 5.0, "Delay should be at most 5s, got \(delay)")
        }
    }

    @Test("Human delay centers around base value")
    func humanDelayDistribution() {
        let samples = (0..<500).map { _ in TimingJitter.humanDelay(base: 0.5) }
        let mean = samples.reduce(0, +) / Double(samples.count)
        // Log-normal mean = exp(mu + sigma^2/2) ≈ 0.54 for base=0.5, sigma=0.4
        #expect(mean > 0.25, "Mean should be above 0.25, got \(mean)")
        #expect(mean < 1.2, "Mean should be below 1.2, got \(mean)")
    }

    @Test("Typing delay is within realistic range")
    func typingDelayRange() {
        for _ in 0..<100 {
            let delay = TimingJitter.typingDelay()
            #expect(delay >= 0.03, "Too fast: \(delay)")
            #expect(delay <= 0.25, "Too slow: \(delay)")
        }
    }

    @Test("Burst typing includes occasional pauses")
    func burstTypingPattern() {
        var normalCount = 0
        var pauseCount = 0
        for i in 0..<100 {
            let delay = TimingJitter.burstTypingDelay(charIndex: i)
            if delay > 0.15 {
                pauseCount += 1
            } else {
                normalCount += 1
            }
        }
        // There should be some pauses (word boundaries) but not too many
        #expect(pauseCount > 0, "Should have at least some burst pauses")
        #expect(normalCount > pauseCount, "Normal keystrokes should outnumber pauses")
    }

    @Test("Coordinate jitter stays within radius")
    func coordinateJitter() {
        let origin = CGPoint(x: 100, y: 200)
        for _ in 0..<100 {
            let jittered = TimingJitter.jitter(origin, radius: 3.0)
            let dx = abs(jittered.x - origin.x)
            let dy = abs(jittered.y - origin.y)
            #expect(dx <= 3.0, "X jitter exceeded radius: \(dx)")
            #expect(dy <= 3.0, "Y jitter exceeded radius: \(dy)")
        }
    }

    // MARK: - BehavioralMimicry

    @Test("Mouse path starts and ends at correct points")
    func mousePathEndpoints() {
        let from = CGPoint(x: 100, y: 100)
        let to = CGPoint(x: 500, y: 300)
        let path = BehavioralMimicry.mousePath(from: from, to: to, steps: 10)

        #expect(path.count == 11, "Should have steps+1 points")
        #expect(path.first!.x == from.x)
        #expect(path.first!.y == from.y)
        #expect(path.last!.x == to.x)
        #expect(path.last!.y == to.y)
    }

    @Test("Mouse path is not a straight line")
    func mousePathCurvature() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 400, y: 0)
        let path = BehavioralMimicry.mousePath(from: from, to: to, steps: 10)

        // At least one midpoint should deviate from Y=0 (Bezier curve)
        let midpoints = path.dropFirst().dropLast()
        let hasDeviation = midpoints.contains { abs($0.y) > 0.5 }
        #expect(hasDeviation, "Path should curve, not be a straight line")
    }

    @Test("Short mouse path handles nearby targets")
    func shortMousePath() {
        let from = CGPoint(x: 100, y: 100)
        let to = CGPoint(x: 110, y: 105)
        let path = BehavioralMimicry.shortMousePath(from: from, to: to)

        #expect(path.count >= 2, "Should have at least start and end")
        #expect(path.first!.x == from.x)
        #expect(path.last!.x == to.x)
    }

    @Test("Click offset stays within element bounds")
    func clickOffsetBounds() {
        let center = CGPoint(x: 200, y: 150)
        for _ in 0..<100 {
            let offset = BehavioralMimicry.clickOffset(center: center, width: 80, height: 30)
            let dx = abs(offset.x - center.x)
            let dy = abs(offset.y - center.y)
            #expect(dx <= 5.0, "X offset too large: \(dx)")
            #expect(dy <= 3.0, "Y offset too large: \(dy)")
        }
    }

    @Test("Pre-action scroll is bounded")
    func preActionScroll() {
        var scrollCount = 0
        for _ in 0..<100 {
            let amount = BehavioralMimicry.preActionScrollAmount()
            #expect(amount >= 0 && amount <= 3)
            if amount > 0 { scrollCount += 1 }
        }
        // ~25% should scroll (binomial: expect 15-35 in 100 trials)
        #expect(scrollCount >= 5, "Too few scrolls: \(scrollCount)")
        #expect(scrollCount <= 50, "Too many scrolls: \(scrollCount)")
    }
}
