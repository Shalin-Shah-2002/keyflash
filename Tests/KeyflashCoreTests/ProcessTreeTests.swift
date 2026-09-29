import Foundation
import XCTest
@testable import KeyflashCore

final class ProcessTreeTests: XCTestCase {
    func testParentOfThisProcessIsOurParent() {
        XCTAssertEqual(ProcessTree.parent(of: Int(getpid())), Int(getppid()))
    }

    func testUnknownProcessHasNoParent() {
        XCTAssertNil(ProcessTree.parent(of: 999_999_999))
    }

    func testAncestorsStartWithTheProcessAndWalkUp() {
        let chain = ProcessTree.ancestors(startingAt: Int(getpid()))
        XCTAssertEqual(chain.first, Int(getpid()))
        XCTAssertEqual(chain.dropFirst().first, Int(getppid()))
        XCTAssertEqual(Set(chain).count, chain.count, "no repeats")
        XCTAssertFalse(chain.contains(0))
        XCTAssertFalse(chain.contains(1), "stops before launchd/init")
    }

    func testLimitIsRespected() {
        XCTAssertLessThanOrEqual(ProcessTree.ancestors(startingAt: Int(getpid()), limit: 1).count, 1)
    }

    func testAChildReportsItsParent() throws {
        // `sh -c 'echo $PPID'` prints the pid of the process that spawned it: us.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "echo $$; echo $PPID"]
        let out = Pipe()
        task.standardOutput = out
        try task.run()
        task.waitUntilExit()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int($0) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(ProcessTree.parent(of: lines[0]) ?? Int(getpid()), Int(getpid()))  // gone by now: either nil or us
        XCTAssertEqual(lines[1], Int(getpid()))
    }
}
