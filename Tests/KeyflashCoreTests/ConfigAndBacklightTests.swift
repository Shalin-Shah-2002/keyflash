import Foundation
import XCTest
@testable import KeyflashCore

final class ConfigAndBacklightTests: SandboxedTestCase {
    func testDefaultsWhenMissing() {
        let config = ConfigLoader.load()
        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.backlightEnabled)
        XCTAssertTrue(config.shouldAutoInstall)
        XCTAssertTrue(config.suppressWhenWatching)
        XCTAssertEqual(config.watchingIdleSeconds, 10)
        XCTAssertEqual(config.terminalBundleIds, KeyflashConfig.defaultTerminalBundleIds)
    }

    func testLoadsWatchingSettings() throws {
        try write("""
        suppressWhenWatching: false
        watchingIdleSeconds: 25
        terminalBundleIds:
          - com.example.Term
          - com.jetbrains.*
        """, to: ".config/keyflash/config.yaml")
        let config = ConfigLoader.load()
        XCTAssertFalse(config.suppressWhenWatching)
        XCTAssertEqual(config.watchingIdleSeconds, 25)
        XCTAssertEqual(config.terminalBundleIds, ["com.example.Term", "com.jetbrains.*"])
    }

    func testWatchingWindowIsClamped() throws {
        try write("watchingIdleSeconds: -5\n", to: ".config/keyflash/config.yaml")
        XCTAssertEqual(ConfigLoader.load().watchingIdleSeconds, 0)
        try write("watchingIdleSeconds: 999999\n", to: ".config/keyflash/config.yaml")
        XCTAssertEqual(ConfigLoader.load().watchingIdleSeconds, 3600)
    }

    func testLoadsValues() throws {
        try write("enabled: false\nbacklightEnabled: false\nshouldAutoInstall: false\ndebugMode: true\n",
                  to: ".config/keyflash/config.yaml")
        let config = ConfigLoader.load()
        XCTAssertFalse(config.enabled)
        XCTAssertFalse(config.backlightEnabled)
        XCTAssertFalse(config.shouldAutoInstall)
        XCTAssertTrue(config.debugMode)
    }

    func testFlashArgumentsCoverRequestedDuration() {
        XCTAssertEqual(Backlight.flashArguments(duration: 1800), ["-f", "2250", "0.4", "200"])
        XCTAssertEqual(Backlight.flashArguments(duration: 0), ["-f", "1", "0.4", "200"])
    }

    func testFlashArgumentsSurviveDegenerateInput() {
        // A zero interval used to trap converting infinity to Int.
        let args = Backlight.flashArguments(duration: 60, interval: 0, fadeMs: -5)
        XCTAssertEqual(args[0], "-f")
        XCTAssertGreaterThan(Int(args[1])!, 0)
        XCTAssertGreaterThan(Double(args[2])!, 0)
        XCTAssertEqual(args[3], "0")
    }

    func testLogWritesToUserLogAndRotates() throws {
        keyflashLog("hello")
        XCTAssertTrue(read("Library/Logs/keyflash.log")?.contains("hello") ?? false)

        try String(repeating: "x", count: 1_100_000).write(to: KeyflashPaths.logFile, atomically: true, encoding: .utf8)
        keyflashLog("after rotation")
        XCTAssertEqual(read("Library/Logs/keyflash.log")?.contains("after rotation"), true)
        XCTAssertLessThan(read("Library/Logs/keyflash.log")?.count ?? .max, 1000)
        XCTAssertNotNil(read("Library/Logs/keyflash.log.1"))
    }

    func testLogRefusesSymlink() throws {
        let target = home.appendingPathComponent("victim")
        try "orig".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: KeyflashPaths.logFile, withDestinationURL: target)
        keyflashLog("should not be written")
        XCTAssertEqual(read("victim"), "orig")
    }
}
