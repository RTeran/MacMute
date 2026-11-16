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

    func testRejectsAPeerThatDoesNotSatisfyTheRequirement() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "com.macmute.helper""# as CFString, [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: try XCTUnwrap(requirement))

        guard case .failure(.requirementNotSatisfied) = result else {
            return XCTFail("Expected requirementNotSatisfied, got \(result)")
        }
    }

    func testRejectsAPeerThatDoesNotSatisfyTheDesignatedRequirementOfOtherCode() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try staticCode(at: URL(fileURLWithPath: "/bin/ls")), [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: try XCTUnwrap(requirement))

        guard case .failure(.requirementNotSatisfied) = result else {
            return XCTFail("Expected requirementNotSatisfied, got \(result)")
        }
    }

    func testRejectsASocketWithoutPeer() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: -1, against: try XCTUnwrap(requirement))

        guard case .failure(.peerTokenUnavailable) = result else {
            return XCTFail("Expected peerTokenUnavailable, got \(result)")
        }
    }

    // /bin/ls stands in for both the app and the helper: it carries a certificate chain and its own identifier.
    func testAnAppWithACertificateTrustsCodeWithTheIdentifierSignedByTheSameLeaf() throws {
        let signed = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signed, helperIdentifier: "com.apple.ls", bundledHelper: missingHelper
        ).get()

        let text = try requirementText(requirement)
        XCTAssertEqual(SecStaticCodeCheckValidity(signed, [], requirement), errSecSuccess, text)
    }

    func testAnAppWithACertificateRejectsCodeWithAnotherIdentifier() throws {
        let signed = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signed, helperIdentifier: "com.macmute.helper", bundledHelper: missingHelper
        ).get()

        XCTAssertEqual(SecStaticCodeCheckValidity(signed, [], requirement), errSecCSReqFailed)
    }

    func testReportsARequirementThatCannotBeBuilt() throws {
        let signedApp = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let result = PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signedApp, helperIdentifier: #"broken" and"#, bundledHelper: missingHelper
        )

        guard case let .failure(error) = result, case .requirementUnbuildable = error else {
            return XCTFail("Expected requirementUnbuildable, got \(result)")
        }
        XCTAssertTrue(error.description.contains("cannot build the trusted helper requirement"), error.description)
    }

    func testAnAdHocAppTrustsTheDesignatedRequirementOfTheBundledHelper() throws {
        let adHocApp = try adHocTestBundle()

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: adHocApp, helperIdentifier: "com.macmute.helper", bundledHelper: try ownCodeURL()
        ).get()

        XCTAssertNoThrow(try PeerCodeVerifier.verify(socket: sockets[0], against: requirement).get())
    }

    func testAnAdHocAppWithoutTheBundledHelperHasNoRequirement() throws {
        let adHocApp = try adHocTestBundle()
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
        let adHocApp = try adHocTestBundle()
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

    func testReadsTheSignatureOfTheRunningCode() throws {
        var path: CFURL?
        XCTAssertEqual(SecCodeCopyPath(try PeerCodeVerifier.ownStaticCode().get(), [], &path), errSecSuccess)

        XCTAssertEqual(try XCTUnwrap(path) as URL, try ownCodeURL())
    }

    func testDescribesAnUnreadableHelperWithoutItsDirectory() {
        let error = PeerVerificationError.expectedCodeUnavailable(path: "/Users/someone/MacMute.app/Contents/Resources/MacMuteHelper", status: -1)

        XCTAssertTrue(error.description.contains("MacMuteHelper"), error.description)
        XCTAssertFalse(error.description.contains("someone"), error.description)
    }

    func testFindsTheAppThatBundlesTheHelper() {
        let helper = URL(fileURLWithPath: "/Applications/MacMute.app/Contents/Resources/MacMuteHelper")

        XCTAssertEqual(PeerCodeVerifier.containingApp(ofHelperAt: helper), URL(fileURLWithPath: "/Applications/MacMute.app"))
    }

    func testAHelperOutsideAnAppHasNoContainingApp() {
        XCTAssertNil(PeerCodeVerifier.containingApp(ofHelperAt: URL(fileURLWithPath: "/usr/local/bin/MacMuteHelper")))
    }

    func testAHelperOutsideTheAppResourcesHasNoContainingApp() {
        XCTAssertNil(PeerCodeVerifier.containingApp(ofHelperAt: URL(fileURLWithPath: "/Applications/MacMute.app/Contents/MacOS/MacMuteHelper")))
    }

    func testAHelperWithACertificateTrustsAnAppWithTheIdentifierSignedByTheSameLeaf() throws {
        let signed = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        let missingApp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).app")

        let requirement = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: signed, appIdentifier: "com.apple.ls", containingApp: missingApp
        ).get()

        let text = try requirementText(requirement)
        XCTAssertEqual(SecStaticCodeCheckValidity(signed, [], requirement), errSecSuccess, text)
    }

    func testAHelperWithACertificateRejectsAnAppWithAnotherIdentifier() throws {
        let signed = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        let missingApp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).app")

        let requirement = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: signed, appIdentifier: PeerCodeVerifier.appIdentifier, containingApp: missingApp
        ).get()

        XCTAssertEqual(SecStaticCodeCheckValidity(signed, [], requirement), errSecCSReqFailed)
    }

    func testAnAdHocHelperTrustsTheDesignatedRequirementOfTheContainingApp() throws {
        let adHocHelper = try adHocTestBundle()

        let requirement = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: adHocHelper, appIdentifier: PeerCodeVerifier.appIdentifier, containingApp: try ownCodeURL()
        ).get()

        XCTAssertNoThrow(try PeerCodeVerifier.verify(socket: sockets[0], against: requirement).get())
    }

    func testAHelperUnderAFolderOtherThanContentsHasNoContainingApp() {
        XCTAssertNil(PeerCodeVerifier.containingApp(ofHelperAt: URL(fileURLWithPath: "/Applications/MacMute.app/Other/Resources/MacMuteHelper")))
    }

    func testAHelperInABundleWithoutTheAppExtensionHasNoContainingApp() {
        XCTAssertNil(PeerCodeVerifier.containingApp(ofHelperAt: URL(fileURLWithPath: "/Applications/MacMute/Contents/Resources/MacMuteHelper")))
    }

    func testTheHelperTrustsTheIdentifierTheAppIsSignedWith() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("MacMute.xcodeproj/project.pbxproj"), encoding: .utf8)

        XCTAssertEqual(project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = \(PeerCodeVerifier.appIdentifier);").count - 1, 2)
    }

    func testDescribesASecurityCallThatReturnedNothingWithoutAnOSStatus() {
        let description = PeerVerificationError.securityCallReturnedNothing("SecCodeCopySelf").description

        XCTAssertFalse(description.contains("OSStatus"), description)
        XCTAssertTrue(description.contains("SecCodeCopySelf"), description)
    }

    func testReportsThePeerProcessId() {
        XCTAssertEqual(PeerCodeVerifier.peerProcessID(of: sockets[0]), getpid())
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    private func adHocTestBundle() throws -> SecStaticCode {
        let code = try staticCode(at: Bundle(for: Self.self).bundleURL)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        if let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty {
            throw XCTSkip("The test bundle is signed with a certificate; these tests need an ad-hoc one")
        }
        return code
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
