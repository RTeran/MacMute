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
