import Security
import XCTest

final class PeerCodeVerifierTests: XCTestCase {
    private var sockets: [Int32] = [-1, -1]

    override func setUp() {
        super.setUp()
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    }

    override func tearDown() {
        sockets.forEach { close($0) }
        super.tearDown()
    }

    func testAcceptsAPeerRunningTheExpectedCode() throws {
        let result = PeerCodeVerifier.verify(socket: sockets[0], againstCodeAt: try ownCodeURL())

        XCTAssertNoThrow(try result.get())
    }

    func testRejectsAPeerThatDoesNotSatisfyTheRequirement() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "com.macmute.helper""# as CFString, [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: try XCTUnwrap(requirement))

        guard case .failure(.requirementNotSatisfied) = result else {
            return XCTFail("Expected requirementNotSatisfied, got \(result)")
        }
    }

    func testRejectsWhenTheExpectedCodeIsMissing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let result = PeerCodeVerifier.verify(socket: sockets[0], againstCodeAt: missing)

        guard case .failure(.expectedCodeUnavailable) = result else {
            return XCTFail("Expected expectedCodeUnavailable, got \(result)")
        }
    }

    func testRejectsASocketWithoutPeer() throws {
        let result = PeerCodeVerifier.verify(socket: -1, againstCodeAt: try ownCodeURL())

        guard case .failure(.peerTokenUnavailable) = result else {
            return XCTFail("Expected peerTokenUnavailable, got \(result)")
        }
    }

    func testAnAppWithACertificateTrustsTheHelperIdentifierSignedByTheSameLeaf() throws {
        let signedApp = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signedApp, helperIdentifier: "com.macmute.helper", bundledHelper: missingHelper
        ).get()

        let text = try requirementText(requirement)
        XCTAssertNotNil(text.range(of: #"^identifier "com\.macmute\.helper" and certificate leaf = H"[0-9a-f]{40}"$"#, options: .regularExpression), text)
    }

    func testAnAdHocAppTrustsTheDesignatedRequirementOfTheBundledHelper() throws {
        let adHocApp = try staticCode(at: Bundle(for: Self.self).bundleURL)

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: adHocApp, helperIdentifier: "com.macmute.helper", bundledHelper: try ownCodeURL()
        ).get()

        XCTAssertNoThrow(try PeerCodeVerifier.verify(socket: sockets[0], against: requirement).get())
    }

    func testAnAdHocAppWithoutTheBundledHelperHasNoRequirement() throws {
        let adHocApp = try staticCode(at: Bundle(for: Self.self).bundleURL)
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let result = PeerCodeVerifier.trustedHelperRequirement(
            signedLike: adHocApp, helperIdentifier: "com.macmute.helper", bundledHelper: missingHelper
        )

        guard case let .failure(.expectedCodeUnavailable(path, _)) = result else {
            return XCTFail("Expected expectedCodeUnavailable, got \(result)")
        }
        XCTAssertEqual(path, missingHelper.path)
    }

    func testReplacingTheBundledHelperAfterTheRequirementIsBuiltChangesNothing() throws {
        let helper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: helper) }
        try FileManager.default.copyItem(at: try ownCodeURL(), to: helper)
        let adHocApp = try staticCode(at: Bundle(for: Self.self).bundleURL)
        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: adHocApp, helperIdentifier: "com.macmute.helper", bundledHelper: helper
        ).get()

        try FileManager.default.removeItem(at: helper)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: helper)

        XCTAssertNoThrow(try PeerCodeVerifier.verify(socket: sockets[0], against: requirement).get())
        let rebuilt = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: adHocApp, helperIdentifier: "com.macmute.helper", bundledHelper: helper
        ).get()
        XCTAssertThrowsError(try PeerCodeVerifier.verify(socket: sockets[0], against: rebuilt).get())
    }

    func testReportsThePeerProcessId() {
        XCTAssertEqual(PeerCodeVerifier.peerProcessID(of: sockets[0]), getpid())
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    private func requirementText(_ requirement: SecRequirement) throws -> String {
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(requirement, [], &text), errSecSuccess)
        return try XCTUnwrap(text) as String
    }

    private func ownCodeURL() throws -> URL {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var url: CFURL?
        XCTAssertEqual(SecCodeCopyPath(try XCTUnwrap(staticCode), [], &url), errSecSuccess)
        return try XCTUnwrap(url) as URL
    }
}
