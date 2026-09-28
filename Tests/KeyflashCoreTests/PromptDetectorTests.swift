import Foundation
import XCTest
@testable import KeyflashCore

final class PromptDetectorTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private lazy var detector = PromptDetector(now: { [unowned self] in self.clock })

    private func advance(_ seconds: TimeInterval) { clock += seconds }
    private func type(_ text: String) { detector.noteUserInput(Array(text.utf8)) }
    private func output(_ text: String = "x") { detector.feed(Data(text.utf8)) }

    func testPausingWhileTypingDoesNotFire() {
        type("h"); output("h")          // echo
        advance(0.05); type("i"); output("i")
        advance(5)
        XCTAssertFalse(detector.checkIdleSilence())
    }

    func testEchoOfEnterAloneDoesNotFire() {
        type("\r"); output("\r\n")      // immediate echo/redraw only
        advance(5)
        XCTAssertFalse(detector.checkIdleSilence())
    }

    func testResponseThenSilenceFiresOnce() {
        type("do it\r"); output("\r\n")
        advance(0.5); output("working...")
        advance(1.0); output("done")
        advance(1.0)
        XCTAssertFalse(detector.checkIdleSilence(), "not silent long enough yet")
        advance(0.6)
        XCTAssertTrue(detector.checkIdleSilence())
        advance(5)
        XCTAssertFalse(detector.checkIdleSilence(), "fires once per prompt")
    }

    func testNoFireWithoutAnyPrompt() {
        output("startup banner")
        advance(5)
        XCTAssertFalse(detector.checkIdleSilence())
    }

    func testNextPromptRearms() {
        type("a\n"); advance(0.5); output("answer"); advance(2)
        XCTAssertTrue(detector.checkIdleSilence())
        type("b\n"); advance(0.5); output("answer 2"); advance(2)
        XCTAssertTrue(detector.checkIdleSilence())
    }
}
