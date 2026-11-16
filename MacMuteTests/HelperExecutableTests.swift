import XCTest

final class HelperExecutableTests: XCTestCase {
    private var helper: URL!

    override func setUpWithError() throws {
        helper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-helper-\(UUID().uuidString.prefix(8))")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
    }

    override func tearDown() {
        chflags(helper.path, 0)
        try? FileManager.default.removeItem(at: helper)
        super.tearDown()
    }

    // An immutable file stands in for a bundle owned by another user or on a read-only volume.
    func testAcceptsAnExecutableHelperThatCannotBeChanged() {
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        XCTAssertEqual(chflags(helper.path, UInt32(UF_IMMUTABLE)), 0)

        let result = ensureExecutable(atPath: helper.path)

        XCTAssertTrue(result.isExecutable)
        XCTAssertNil(result.chmodError)
    }

    func testAcceptsAnExecutableHelperOwnedByAnotherUser() throws {
        let path = "/bin/ls"
        let owner = try FileManager.default.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber
        XCTAssertNotEqual(owner?.uint32Value, getuid())

        let result = ensureExecutable(atPath: path)

        XCTAssertTrue(result.isExecutable)
        XCTAssertNil(result.chmodError)
    }

    func testMakesAHelperThatIsNotExecutableExecutable() throws {
        XCTAssertEqual(chmod(helper.path, 0o644), 0)

        let result = ensureExecutable(atPath: helper.path)

        XCTAssertTrue(result.isExecutable)
        XCTAssertNil(result.chmodError)
        let mode = try FileManager.default.attributesOfItem(atPath: helper.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func testReportsAHelperThatStaysNotExecutable() {
        XCTAssertEqual(chmod(helper.path, 0o644), 0)
        XCTAssertEqual(chflags(helper.path, UInt32(UF_IMMUTABLE)), 0)

        let result = ensureExecutable(atPath: helper.path)

        XCTAssertFalse(result.isExecutable)
        XCTAssertNotNil(result.chmodError)
    }
}
