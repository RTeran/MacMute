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

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: TrustedPeer(requirement: try XCTUnwrap(requirement), requiresHardenedRuntime: false))

        guard case .failure(.requirementNotSatisfied) = result else {
            return XCTFail("Expected requirementNotSatisfied, got \(result)")
        }
    }

    func testRejectsAPeerThatDoesNotSatisfyTheDesignatedRequirementOfOtherCode() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try staticCode(at: URL(fileURLWithPath: "/bin/ls")), [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: TrustedPeer(requirement: try XCTUnwrap(requirement), requiresHardenedRuntime: false))

        guard case .failure(.requirementNotSatisfied) = result else {
            return XCTFail("Expected requirementNotSatisfied, got \(result)")
        }
    }

    func testRejectsASocketWithoutPeer() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: -1, against: TrustedPeer(requirement: try XCTUnwrap(requirement), requiresHardenedRuntime: false))

        guard case .failure(.peerTokenUnavailable) = result else {
            return XCTFail("Expected peerTokenUnavailable, got \(result)")
        }
    }

    // /bin/ls stands in for both the app and the helper: it carries a certificate chain and its own identifier.
    func testAnAppWithACertificateTrustsCodeWithTheIdentifierSignedByTheSameLeaf() throws {
        let signed = try certificateSignedCode()
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signed, helperIdentifier: "com.apple.ls", bundledHelper: missingHelper
        ).get()

        let text = try requirementText(requirement.requirement)
        XCTAssertEqual(SecStaticCodeCheckValidity(signed.staticCode, [], requirement.requirement), errSecSuccess, text)
    }

    func testAnAppWithACertificateRejectsCodeWithAnotherIdentifier() throws {
        let signed = try certificateSignedCode()
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let requirement = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signed, helperIdentifier: "com.macmute.helper", bundledHelper: missingHelper
        ).get()

        XCTAssertEqual(SecStaticCodeCheckValidity(signed.staticCode, [], requirement.requirement), errSecCSReqFailed)
    }

    func testReportsARequirementThatCannotBeBuilt() throws {
        let signedApp = try certificateSignedCode()
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
        XCTAssertEqual(SecCodeCopyPath(try runningOwnCodeWithoutPin().staticCode, [], &path), errSecSuccess)

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
        let signed = try certificateSignedCode()
        let missingApp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).app")

        let requirement = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: signed, appIdentifier: "com.apple.ls", containingApp: missingApp
        ).get()

        let text = try requirementText(requirement.requirement)
        XCTAssertEqual(SecStaticCodeCheckValidity(signed.staticCode, [], requirement.requirement), errSecSuccess, text)
    }

    func testAHelperWithACertificateRejectsAnAppWithAnotherIdentifier() throws {
        let signed = try certificateSignedCode()
        let missingApp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).app")

        let requirement = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: signed, appIdentifier: PeerCodeVerifier.appIdentifier, containingApp: missingApp
        ).get()

        XCTAssertEqual(SecStaticCodeCheckValidity(signed.staticCode, [], requirement.requirement), errSecCSReqFailed)
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

    func testAcceptsAPeerWithTheHardenedRuntimeWhenItIsRequired() {
        XCTAssertNoThrow(try PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: runtimeFlag | adHocFlag, required: true).get())
    }

    func testRejectsAPeerWithoutTheHardenedRuntimeWhenItIsRequired() {
        let result = PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: adHocFlag, required: true)

        XCTAssertEqual(result.failure, .peerWithoutHardenedRuntime)
    }

    func testReportsSigningInformationWithoutAStatus() {
        XCTAssertEqual(PeerCodeVerifier.codeStatus(from: [:]).failure, .securityCallReturnedNothing("kSecCodeInfoStatus"))
    }

    func testReadsTheStatusFromSigningInformation() throws {
        let information: [String: Any] = [kSecCodeInfoStatus as String: NSNumber(value: runtimeFlag)]

        XCTAssertEqual(try PeerCodeVerifier.codeStatus(from: information).get(), runtimeFlag)
    }

    func testIgnoresTheHardenedRuntimeWhenItIsNotRequired() {
        XCTAssertNoThrow(try PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: adHocFlag, required: false).get())
    }

    func testAnAppWithACertificateRequiresTheHardenedRuntimeFromTheHelper() throws {
        let signed = try certificateSignedCode()
        let missingHelper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)")

        let trusted = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: signed, helperIdentifier: "com.apple.ls", bundledHelper: missingHelper
        ).get()

        XCTAssertTrue(trusted.requiresHardenedRuntime)
    }

    func testAHelperWithACertificateRequiresTheHardenedRuntimeFromTheApp() throws {
        let signed = try certificateSignedCode()
        let missingApp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).app")

        let trusted = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: signed, appIdentifier: "com.apple.ls", containingApp: missingApp
        ).get()

        XCTAssertTrue(trusted.requiresHardenedRuntime)
    }

    func testAnAdHocAppDoesNotRequireTheHardenedRuntime() throws {
        let trusted = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: try adHocTestBundle(), helperIdentifier: "com.macmute.helper", bundledHelper: try ownCodeURL()
        ).get()

        XCTAssertFalse(trusted.requiresHardenedRuntime)
    }

    func testAnAdHocHelperDoesNotRequireTheHardenedRuntime() throws {
        let trusted = try PeerCodeVerifier.trustedAppRequirement(
            signedLike: try adHocTestBundle(), appIdentifier: PeerCodeVerifier.appIdentifier, containingApp: try ownCodeURL()
        ).get()

        XCTAssertFalse(trusted.requiresHardenedRuntime)
    }

    func testRejectsATrustedPeerWithoutTheHardenedRuntimeWhenItIsRequired() throws {
        try XCTSkipIf(ownCodeHasHardenedRuntime(), "this test process runs with the hardened runtime")
        let requirement = try ownDesignatedRequirement()

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: TrustedPeer(requirement: requirement, requiresHardenedRuntime: true))

        XCTAssertEqual(result.failure, .peerWithoutHardenedRuntime)
    }

    func testAcceptsATrustedPeerWithoutTheHardenedRuntimeWhenItIsNotRequired() throws {
        let requirement = try ownDesignatedRequirement()

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: TrustedPeer(requirement: requirement, requiresHardenedRuntime: false))

        XCTAssertNoThrow(try result.get())
    }

    func testStillReportsAnUntrustedPeerBeforeTheHardenedRuntime() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "com.macmute.helper""# as CFString, [], &requirement), errSecSuccess)

        let result = PeerCodeVerifier.verify(socket: sockets[0], against: TrustedPeer(requirement: try XCTUnwrap(requirement), requiresHardenedRuntime: true))

        guard case .failure(.requirementNotSatisfied) = result else {
            return XCTFail("Expected requirementNotSatisfied, got \(result)")
        }
    }

    func testDescribesAPeerWithoutTheHardenedRuntime() {
        XCTAssertTrue(PeerVerificationError.peerWithoutHardenedRuntime.description.contains("hardened runtime"))
    }

    func testAnOnDiskSignatureThatIsNotTheRunningCodeIsRejected() throws {
        let result = PeerCodeVerifier.ownCode(running: try runningCode(), onDisk: try staticCode(at: URL(fileURLWithPath: "/bin/ls")))

        guard case .failure(.ownSignatureInvalid) = result else {
            return XCTFail("Expected ownSignatureInvalid, got \(result)")
        }
    }

    func testTheRunningCodeMatchesItsOwnSignatureOnDisk() throws {
        XCTAssertNil(try runningOwnCodeWithoutPin().leaf)
    }

    func testTheRunningAdHocCodeTrustsNothingWhenAPinIsSet() throws {
        let result = PeerCodeVerifier.ownCode(
            running: try runningCode(), onDisk: try staticCode(at: try ownCodeURL()), pinReader: { _ in .success(self.pinnedHash) }
        )

        XCTAssertEqual(result.failure, .ownLeafNotPinned)
    }

    // The test process is xctest, whose Info.plist has no pin key, unlike the app and the helper.
    func testRunningCodeWithoutAPinKeyTrustsNothing() {
        XCTAssertEqual(PeerCodeVerifier.ownCode().failure, .securityCallReturnedNothing(PeerCodeVerifier.leafPinKey))
    }

    func testReportsAPeerStatusThatCannotBeRead() throws {
        let requirement = try ownDesignatedRequirement()

        let result = PeerCodeVerifier.verify(
            socket: sockets[0], against: TrustedPeer(requirement: requirement, requiresHardenedRuntime: true),
            statusReader: { _ in .failure(.peerStatusUnavailable(errSecCSInvalidObjectRef)) }
        )

        XCTAssertEqual(result.failure, .peerStatusUnavailable(errSecCSInvalidObjectRef))
        XCTAssertTrue(PeerVerificationError.peerStatusUnavailable(errSecCSInvalidObjectRef).description.contains("\(errSecCSInvalidObjectRef)"))
    }

    func testDoesNotReadTheStatusOfAnUntrustedPeer() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "com.macmute.helper""# as CFString, [], &requirement), errSecSuccess)
        var statusWasRead = false

        _ = PeerCodeVerifier.verify(
            socket: sockets[0], against: TrustedPeer(requirement: try XCTUnwrap(requirement), requiresHardenedRuntime: true),
            statusReader: { _ in statusWasRead = true; return .success(self.runtimeFlag) }
        )

        XCTAssertFalse(statusWasRead)
    }

    func testAcceptsATrustedPeerThatRunsWithTheHardenedRuntime() throws {
        let requirement = try ownDesignatedRequirement()

        let result = PeerCodeVerifier.verify(
            socket: sockets[0], against: TrustedPeer(requirement: requirement, requiresHardenedRuntime: true),
            statusReader: { _ in .success(self.runtimeFlag) }
        )

        XCTAssertNoThrow(try result.get())
    }

    func testRejectsAPeerThatAllowsADebuggerWhenTheHardenedRuntimeIsRequired() {
        let result = PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: runtimeFlag | PeerCodeVerifier.getTaskAllowFlag, required: true)

        XCTAssertEqual(result.failure, .peerIsDebuggable)
    }

    func testRejectsAPeerWithADebuggerAttachedWhenTheHardenedRuntimeIsRequired() {
        let result = PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: runtimeFlag | PeerCodeVerifier.debuggedFlag, required: true)

        XCTAssertEqual(result.failure, .peerIsDebuggable)
    }

    func testReportsAMissingHardenedRuntimeBeforeADebuggablePeer() {
        let result = PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: PeerCodeVerifier.getTaskAllowFlag, required: true)

        XCTAssertEqual(result.failure, .peerWithoutHardenedRuntime)
    }

    func testIgnoresDebuggableFlagsWhenTheHardenedRuntimeIsNotRequired() {
        let status = PeerCodeVerifier.getTaskAllowFlag | PeerCodeVerifier.debuggedFlag

        XCTAssertNoThrow(try PeerCodeVerifier.hardenedRuntimeCheck(codeStatus: status, required: false).get())
    }

    func testDescribesADebuggablePeer() {
        XCTAssertTrue(PeerVerificationError.peerIsDebuggable.description.contains("debugger"))
    }

    func testTheRunningAdHocTestHostUsesTheAdHocBranchWithoutInjection() throws {
        _ = try adHocTestBundle()

        let trusted = try PeerCodeVerifier.trustedHelperRequirement(
            signedLike: try runningOwnCodeWithoutPin(), helperIdentifier: "com.macmute.helper", bundledHelper: try ownCodeURL()
        ).get()

        XCTAssertFalse(trusted.requiresHardenedRuntime)
        XCTAssertNoThrow(try PeerCodeVerifier.verify(socket: sockets[0], against: trusted).get())
    }

    func testUsesTheKernelValuesOfTheDebuggableFlags() {
        XCTAssertEqual(PeerCodeVerifier.getTaskAllowFlag, 0x4)
        XCTAssertEqual(PeerCodeVerifier.debuggedFlag, 0x1000_0000)
    }

    func testRejectsADebuggableTrustedPeerThroughTheStatusReader() throws {
        let requirement = try ownDesignatedRequirement()

        let result = PeerCodeVerifier.verify(
            socket: sockets[0], against: TrustedPeer(requirement: requirement, requiresHardenedRuntime: true),
            statusReader: { _ in .success(self.runtimeFlag | PeerCodeVerifier.getTaskAllowFlag) }
        )

        XCTAssertEqual(result.failure, .peerIsDebuggable)
    }

    func testAcceptsAnAdHocSignatureWithoutACertificate() {
        XCTAssertNoThrow(try PeerCodeVerifier.signingModeCheck(staticFlags: adHocFlag | runtimeFlag, hasLeaf: false).get())
    }

    func testAcceptsACertificateSignatureThatIsNotAdHoc() {
        XCTAssertNoThrow(try PeerCodeVerifier.signingModeCheck(staticFlags: runtimeFlag, hasLeaf: true).get())
    }

    func testRejectsASignatureThatIsNeitherAdHocNorHasACertificate() {
        XCTAssertEqual(PeerCodeVerifier.signingModeCheck(staticFlags: runtimeFlag, hasLeaf: false).failure, .ownSigningModeInconsistent)
    }

    func testRejectsAnAdHocSignatureThatHasACertificate() {
        XCTAssertEqual(PeerCodeVerifier.signingModeCheck(staticFlags: adHocFlag, hasLeaf: true).failure, .ownSigningModeInconsistent)
    }

    func testReadsTheStaticSigningFlags() {
        let information: [String: Any] = [kSecCodeInfoFlags as String: NSNumber(value: adHocFlag)]

        XCTAssertEqual(try PeerCodeVerifier.signingFlags(from: information).get(), adHocFlag)
    }

    func testRejectsMissingStaticSigningFlags() {
        XCTAssertEqual(PeerCodeVerifier.signingFlags(from: [:]).failure, .securityCallReturnedNothing("kSecCodeInfoFlags"))
    }

    func testRejectsStaticSigningFlagsOfTheWrongType() {
        let information: [String: Any] = [kSecCodeInfoFlags as String: "2"]

        XCTAssertEqual(PeerCodeVerifier.signingFlags(from: information).failure, .securityCallReturnedNothing("kSecCodeInfoFlags"))
    }

    func testAnEmptyPinKeepsBothTrustBranches() {
        XCTAssertNoThrow(try PeerCodeVerifier.leafPinCheck(pin: nil, leafHash: nil).get())
        XCTAssertNoThrow(try PeerCodeVerifier.leafPinCheck(pin: nil, leafHash: pinnedHash).get())
    }

    func testAcceptsALeafThatMatchesThePin() {
        XCTAssertNoThrow(try PeerCodeVerifier.leafPinCheck(pin: pinnedHash, leafHash: pinnedHash).get())
    }

    func testRejectsALeafThatDoesNotMatchThePin() {
        let other = String(repeating: "0", count: 40)

        XCTAssertEqual(PeerCodeVerifier.leafPinCheck(pin: pinnedHash, leafHash: other).failure, .ownLeafNotPinned)
    }

    func testRejectsAnAdHocSignatureWhenAPinIsSet() {
        XCTAssertEqual(PeerCodeVerifier.leafPinCheck(pin: pinnedHash, leafHash: nil).failure, .ownLeafNotPinned)
    }

    func testReadsAnEmptyPinAsNoPin() throws {
        XCTAssertNil(try PeerCodeVerifier.leafPin(from: [PeerCodeVerifier.leafPinKey: ""]).get())
    }

    func testReadsTheHexPin() throws {
        XCTAssertEqual(try PeerCodeVerifier.leafPin(from: [PeerCodeVerifier.leafPinKey: pinnedHash]).get(), pinnedHash)
    }

    func testRejectsAMalformedPin() {
        for malformed in ["ea0ccfd73df5b789344b9dfcb73d985c8be24e2", "H\"\(pinnedHash)\"", pinnedHash.uppercased(), "zz" + pinnedHash.dropFirst(2)] {
            XCTAssertEqual(PeerCodeVerifier.leafPin(from: [PeerCodeVerifier.leafPinKey: malformed]).failure, .leafPinMalformed, malformed)
        }
    }

    func testRejectsAMissingPinKey() {
        XCTAssertEqual(PeerCodeVerifier.leafPin(from: [:]).failure, .securityCallReturnedNothing(PeerCodeVerifier.leafPinKey))
    }

    func testRejectsAMissingInfoPlist() {
        XCTAssertEqual(PeerCodeVerifier.leafPin(from: nil).failure, .securityCallReturnedNothing(PeerCodeVerifier.leafPinKey))
    }

    func testRejectsAPinOfTheWrongType() {
        XCTAssertEqual(PeerCodeVerifier.leafPin(from: [PeerCodeVerifier.leafPinKey: 1]).failure, .securityCallReturnedNothing(PeerCodeVerifier.leafPinKey))
    }

    func testRejectsAStatusOfTheWrongType() {
        let information: [String: Any] = [kSecCodeInfoStatus as String: "65536"]

        XCTAssertEqual(PeerCodeVerifier.codeStatus(from: information).failure, .securityCallReturnedNothing("kSecCodeInfoStatus"))
    }

    func testReportsThePeerProcessId() {
        XCTAssertEqual(PeerCodeVerifier.peerProcessID(of: sockets[0]), getpid())
    }

    private func ownDesignatedRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try staticCode(at: try ownCodeURL()), [], &requirement), errSecSuccess)
        return try XCTUnwrap(requirement)
    }

    private func ownCodeHasHardenedRuntime() throws -> Bool {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var info: CFDictionary?
        let staticView = unsafeBitCast(try XCTUnwrap(code), to: SecStaticCode.self)
        XCTAssertEqual(SecCodeCopySigningInformation(staticView, SecCSFlags(rawValue: kSecCSDynamicInformation), &info), errSecSuccess)
        let status = ((info as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value ?? 0
        return status & runtimeFlag != 0
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    private var runtimeFlag: UInt32 { SecCodeSignatureFlags.runtime.rawValue }
    private var adHocFlag: UInt32 { SecCodeSignatureFlags.adhoc.rawValue }
    private let pinnedHash = "ea0ccfd73df5b789344b9dfcb73d985c8be24e20"

    // /bin/ls as the running code of a certificate-signed release.
    private func certificateSignedCode() throws -> OwnCode {
        let ls = try staticCode(at: URL(fileURLWithPath: "/bin/ls"))
        return OwnCode(staticCode: ls, leaf: try XCTUnwrap(PeerCodeVerifier.signingIdentity(of: ls).get().leaf))
    }

    /// The real running code and trust branch, with the empty pin that Xcode builds of the app carry.
    private func runningOwnCodeWithoutPin() throws -> OwnCode {
        try PeerCodeVerifier.ownCode(running: try runningCode(), onDisk: try staticCode(at: try ownCodeURL()), pinReader: { _ in .success(nil) }).get()
    }

    private func runningCode() throws -> SecCode {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    private func adHocTestBundle() throws -> OwnCode {
        let code = try staticCode(at: Bundle(for: Self.self).bundleURL)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        if let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty {
            throw XCTSkip("The test bundle is signed with a certificate; these tests need an ad-hoc one")
        }
        return OwnCode(staticCode: code, leaf: nil)
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

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
