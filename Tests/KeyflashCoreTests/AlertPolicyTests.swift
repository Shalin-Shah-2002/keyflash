import Foundation
import XCTest
@testable import KeyflashCore

final class AlertPolicyTests: XCTestCase {
    private let terminal = "com.apple.Terminal"
    private var config = KeyflashConfig()

    private func decide(_ event: AlertEvent, front: String?, idle: TimeInterval) -> AlertPolicy.Decision {
        AlertPolicy.evaluate(event: event, config: config, frontmostBundleID: front, idleSeconds: idle)
    }

    // MARK: Stay quiet when watching

    func testQuietWhenTerminalFrontmostAndActive() {
        XCTAssertFalse(decide(.done, front: terminal, idle: 2).shouldFlash)
    }

    func testFlashesWhenTerminalFrontmostButIdle() {
        XCTAssertTrue(decide(.done, front: terminal, idle: 30).shouldFlash)
    }

    func testFlashesWhenAnotherAppIsInFront() {
        XCTAssertTrue(decide(.done, front: "com.apple.Safari", idle: 1).shouldFlash)
        XCTAssertTrue(decide(.done, front: nil, idle: 1).shouldFlash)
    }

    func testWindowBoundaryIsExclusive() {
        XCTAssertFalse(decide(.done, front: terminal, idle: 9.9).shouldFlash)
        XCTAssertTrue(decide(.done, front: terminal, idle: 10).shouldFlash)
    }

    func testNeedsYouUsesHalfTheWindow() {
        XCTAssertEqual(AlertPolicy.quietWindow(for: .done, config: config), 10)
        XCTAssertEqual(AlertPolicy.quietWindow(for: .attention, config: config), 5)
        XCTAssertEqual(AlertPolicy.quietWindow(for: .error, config: config), 5)
        XCTAssertFalse(decide(.attention, front: terminal, idle: 4).shouldFlash)
        XCTAssertTrue(decide(.attention, front: terminal, idle: 6).shouldFlash)
        XCTAssertTrue(decide(.done, front: terminal, idle: 6).shouldFlash == false)
    }

    func testCanBeDisabled() {
        config.suppressWhenWatching = false
        XCTAssertTrue(decide(.done, front: terminal, idle: 0).shouldFlash)
    }

    func testCustomWindow() {
        config.watchingIdleSeconds = 60
        XCTAssertFalse(decide(.done, front: terminal, idle: 45).shouldFlash)
    }

    func testEmptyAppListNeverSuppresses() {
        config.terminalBundleIds = []
        XCTAssertTrue(decide(.done, front: terminal, idle: 0).shouldFlash)
    }

    func testBundleMatchingIsCaseInsensitiveWithPrefixWildcards() {
        XCTAssertFalse(decide(.done, front: "COM.APPLE.TERMINAL", idle: 0).shouldFlash)
        XCTAssertFalse(decide(.done, front: "com.jetbrains.intellij", idle: 0).shouldFlash)
        XCTAssertTrue(decide(.done, front: "com.jetbrainsfake.app", idle: 0).shouldFlash, "wildcard is a prefix, not a substring")
        config.terminalBundleIds = ["com.example.*"]
        XCTAssertFalse(decide(.done, front: "com.example.MyTerm", idle: 0).shouldFlash)
    }

    func testSuppressionExplainsWhy() {
        guard case .suppressed(let reason) = decide(.done, front: terminal, idle: 2) else { return XCTFail() }
        XCTAssertTrue(reason.contains(terminal))
    }

    // MARK: Host-app awareness

    private func decide(_ event: AlertEvent, context: WatchContext, idle: TimeInterval) -> AlertPolicy.Decision {
        AlertPolicy.evaluate(event: event, config: config, context: context, idleSeconds: idle)
    }

    func testWatchingMeansTheAgentsOwnAppIsInFront() {
        // The agent runs in an app we don't have in the list; it still counts.
        let ctx = WatchContext(frontmostBundleID: "com.example.UnknownTerm", frontmostPID: 500, agentHostAppPIDs: [500])
        XCTAssertFalse(decide(.done, context: ctx, idle: 1).shouldFlash)
    }

    func testAnotherTerminalInFrontDoesNotCountWhenHostIsKnown() {
        // The agent is in iTerm2 (pid 500); you're typing in Terminal.app (pid 600).
        let ctx = WatchContext(frontmostBundleID: "com.apple.Terminal", frontmostPID: 600, agentHostAppPIDs: [500])
        XCTAssertTrue(decide(.done, context: ctx, idle: 1).shouldFlash)
    }

    func testFallsBackToTheAppListWhenHostIsUnknown() {
        // e.g. the agent runs inside tmux, whose server has no app parent.
        let inList = WatchContext(frontmostBundleID: terminal, frontmostPID: 600, agentHostAppPIDs: [])
        XCTAssertFalse(decide(.done, context: inList, idle: 1).shouldFlash)
        let notInList = WatchContext(frontmostBundleID: "com.apple.Safari", frontmostPID: 700, agentHostAppPIDs: [])
        XCTAssertTrue(decide(.done, context: notInList, idle: 1).shouldFlash)
    }

    func testHostAwareRuleStillNeedsRecentActivity() {
        let ctx = WatchContext(frontmostBundleID: "x", frontmostPID: 500, agentHostAppPIDs: [500])
        XCTAssertTrue(decide(.done, context: ctx, idle: 60).shouldFlash)
        XCTAssertTrue(decide(.attention, context: ctx, idle: 6).shouldFlash)
    }

    func testNoFrontmostAppMeansFlash() {
        let ctx = WatchContext(frontmostBundleID: nil, frontmostPID: nil, agentHostAppPIDs: [500])
        XCTAssertTrue(decide(.done, context: ctx, idle: 0).shouldFlash)
    }

    func testDisabledIgnoresContext() {
        config.suppressWhenWatching = false
        let ctx = WatchContext(frontmostBundleID: "x", frontmostPID: 500, agentHostAppPIDs: [500])
        XCTAssertTrue(decide(.done, context: ctx, idle: 0).shouldFlash)
    }

    // MARK: Events

    func testEventParsingFallsBackToDone() {
        XCTAssertEqual(AlertEvent(wire: nil), .done)
        XCTAssertEqual(AlertEvent(wire: ""), .done)
        XCTAssertEqual(AlertEvent(wire: "nonsense"), .done)
        XCTAssertEqual(AlertEvent(wire: "attention"), .attention)
        XCTAssertEqual(AlertEvent(wire: "error"), .error)
    }

    func testPriorityOrdersUrgency() {
        XCTAssertLessThan(AlertEvent.done.priority, AlertEvent.attention.priority)
        XCTAssertLessThan(AlertEvent.attention.priority, AlertEvent.error.priority)
    }

    func testPatternsAreDistinctAndFasterWhenMoreUrgent() {
        let patterns = AlertEvent.allCases.map(\.pattern)
        XCTAssertEqual(Set(patterns.map(\.interval)).count, 3)
        XCTAssertGreaterThan(AlertEvent.done.pattern.interval, AlertEvent.attention.pattern.interval)
        XCTAssertGreaterThan(AlertEvent.attention.pattern.interval, AlertEvent.error.pattern.interval)
    }

    func testFlashArgumentsPerPatternCoverTheDuration() {
        for event in AlertEvent.allCases {
            let args = Backlight.flashArguments(duration: 1800, pattern: event.pattern)
            XCTAssertEqual(args[0], "-f")
            let cycles = Double(args[1])!
            XCTAssertGreaterThanOrEqual(cycles * 2 * event.pattern.interval, 1799)
            XCTAssertEqual(Double(args[2])!, event.pattern.interval)
            XCTAssertEqual(Int(args[3])!, event.pattern.fadeMs)
        }
    }
}
