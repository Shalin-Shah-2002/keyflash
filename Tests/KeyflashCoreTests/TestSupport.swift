import Foundation
import XCTest
@testable import KeyflashCore

/// Points KeyflashPaths.home at a fresh temporary directory for each test.
class SandboxedTestCase: XCTestCase {
    private var savedHome: URL!
    private var savedRuntimeHome: URL!
    var home: URL!

    override func setUpWithError() throws {
        savedHome = KeyflashPaths.home
        savedRuntimeHome = KeyflashPaths.runtimeHome
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        KeyflashPaths.home = home
        KeyflashPaths.runtimeHome = home
    }

    override func tearDownWithError() throws {
        KeyflashPaths.home = savedHome
        KeyflashPaths.runtimeHome = savedRuntimeHome
        try? FileManager.default.removeItem(at: home)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func json(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(relativePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Directory containing the built products (where keyflash-run lives).
var productsDirectory: URL {
    #if os(macOS)
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
    }
    fatalError("couldn't find the products directory")
    #else
    return Bundle.main.bundleURL
    #endif
}
