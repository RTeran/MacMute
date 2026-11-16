import CryptoKit
import Foundation
import Security

enum PeerVerificationError: Error, Equatable, CustomStringConvertible {
    case ownSignatureUnavailable(OSStatus)
    case ownSignatureInvalid(OSStatus)
    case expectedCodeUnavailable(path: String, status: OSStatus)
    case requirementUnbuildable(OSStatus)
    case peerTokenUnavailable(errno: Int32)
    case peerCodeUnavailable(OSStatus)
    case requirementNotSatisfied(OSStatus)
    case peerStatusUnavailable(OSStatus)
    case peerWithoutHardenedRuntime
    case peerIsDebuggable
    case notInsideAnApp
    case ownPathUnavailable(OSStatus)
    case ownSigningModeMismatch(runningAdHoc: Bool)
    case securityCallReturnedNothing(String)

    var description: String {
        switch self {
        case let .ownSignatureUnavailable(status):
            return "cannot read this app's own signature (OSStatus \(status))"
        case let .ownSignatureInvalid(status):
            return "this app's running code does not match a valid signature on disk (OSStatus \(status))"
        case let .expectedCodeUnavailable(path, status):
            // Logged publicly, and the full path contains the user name.
            return "cannot read the signature of \((path as NSString).lastPathComponent) (OSStatus \(status))"
        case let .requirementUnbuildable(status):
            return "cannot build the trusted helper requirement (OSStatus \(status))"
        case let .peerTokenUnavailable(errno):
            return "cannot read the peer's audit token (\(String(cString: strerror(errno))))"
        case let .peerCodeUnavailable(status):
            return "cannot find the peer's code (OSStatus \(status))"
        case let .requirementNotSatisfied(status):
            return "the peer's code signature does not satisfy the trusted requirement (OSStatus \(status))"
        case let .peerStatusUnavailable(status):
            return "cannot read the peer's runtime status (OSStatus \(status))"
        case .peerWithoutHardenedRuntime:
            return "the peer runs without the hardened runtime, so other code could be injected into it"
        case .peerIsDebuggable:
            return "the peer allows a debugger or has one attached, so other code could control it"
        case .notInsideAnApp:
            return "the helper is not in the Contents/Resources folder of an app"
        case let .ownPathUnavailable(status):
            return "cannot read where this helper's code is (OSStatus \(status))"
        case let .ownSigningModeMismatch(runningAdHoc):
            return runningAdHoc
                ? "this app runs ad-hoc signed but its signature on disk has a certificate"
                : "this app runs signed with a certificate but its signature on disk has none"
        case let .securityCallReturnedNothing(function):
            return "\(function) reported success but returned nothing usable"
        }
    }
}

/// An older release signed by the same certificate but without the hardened runtime still matches
/// the requirement, so a certificate-signed peer must also run with the runtime.
struct TrustedPeer {
    let requirement: SecRequirement
    let requiresHardenedRuntime: Bool
}

/// The status comes from the running process and cannot be changed by replacing files on disk.
struct OwnCode {
    let staticCode: SecStaticCode
    let liveStatus: UInt32
}

enum TrustBranch: Equatable {
    case certificate
    case adHoc
}

/// Checks that the process at the other end of a Unix socket runs trusted code. The trusted
/// requirement is derived from signatures instead of hard-coded hashes, so the same check works
/// for ad-hoc Debug builds and for the signed release.
enum PeerCodeVerifier {
    /// Must match the identifier the helper is signed with (OTHER_CODE_SIGN_FLAGS and scripts/release.sh).
    static let helperIdentifier = "com.macmute.helper"
    /// Must match PRODUCT_BUNDLE_IDENTIFIER of the app target, which codesign uses as its identifier.
    static let appIdentifier = "com.macmute.app"

    /// The on-disk copy decides what is trusted, so it is used only after the running code has been
    /// checked against it.
    static func ownCode() -> Result<OwnCode, PeerVerificationError> {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess else { return .failure(.ownSignatureUnavailable(status)) }
        guard let code else { return .failure(.securityCallReturnedNothing("SecCodeCopySelf")) }
        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { return .failure(.ownSignatureInvalid(status)) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess else { return .failure(.ownSignatureUnavailable(status)) }
        guard let staticCode else { return .failure(.securityCallReturnedNothing("SecCodeCopyStaticCode")) }
        return liveStatus(of: code)
            .mapError { error in
                if case let .peerStatusUnavailable(status) = error { return .ownSignatureUnavailable(status) }
                return error
            }
            .map { OwnCode(staticCode: staticCode, liveStatus: $0) }
    }

    /// The branch follows how this process is really signed, so swapping the bundle on disk for an
    /// ad-hoc copy cannot drop the certificate and hardened runtime checks.
    static func trustBranch(liveStatus: UInt32, hasLeaf: Bool) -> Result<TrustBranch, PeerVerificationError> {
        let runningAdHoc = liveStatus & SecCodeSignatureFlags.adhoc.rawValue != 0
        switch (runningAdHoc, hasLeaf) {
        case (true, false): return .success(.adHoc)
        case (false, true): return .success(.certificate)
        default: return .failure(.ownSigningModeMismatch(runningAdHoc: runningAdHoc))
        }
    }

    /// With a certificate, the helper must carry `helperIdentifier` and be signed by the same leaf
    /// as `app`; the helper file is not read, so replacing it cannot change what is trusted.
    /// An ad-hoc app (Debug) has no certificate to compare with, so it trusts the designated
    /// requirement of the bundled helper as it is on disk now.
    static func trustedHelperRequirement(
        signedLike app: OwnCode, helperIdentifier: String, bundledHelper: URL
    ) -> Result<TrustedPeer, PeerVerificationError> {
        trustedRequirement(signedLike: app, identifier: helperIdentifier, adHocFallback: bundledHelper)
    }

    /// The helper's side of `trustedHelperRequirement`: the app must carry `appIdentifier` and be
    /// signed by the helper's leaf, or, for an ad-hoc helper, match the containing app on disk now.
    static func trustedAppRequirement(
        signedLike helper: OwnCode, appIdentifier: String, containingApp: URL
    ) -> Result<TrustedPeer, PeerVerificationError> {
        trustedRequirement(signedLike: helper, identifier: appIdentifier, adHocFallback: containingApp)
    }

    /// The app copies the helper into Contents/Resources; anywhere else there is no app to trust.
    static func containingApp(ofHelperAt helper: URL) -> URL? {
        let resources = helper.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard resources.lastPathComponent == "Resources", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    static func path(of code: SecStaticCode) -> Result<URL, PeerVerificationError> {
        var url: CFURL?
        let status = SecCodeCopyPath(code, [], &url)
        guard status == errSecSuccess else { return .failure(.ownPathUnavailable(status)) }
        guard let url else { return .failure(.securityCallReturnedNothing("SecCodeCopyPath")) }
        return .success(url as URL)
    }

    private static func trustedRequirement(
        signedLike ownCode: OwnCode, identifier: String, adHocFallback: URL
    ) -> Result<TrustedPeer, PeerVerificationError> {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(ownCode.staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess else { return .failure(.ownSignatureUnavailable(status)) }
        guard let info = info as? [String: Any] else {
            return .failure(.securityCallReturnedNothing("SecCodeCopySigningInformation"))
        }
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        return trustBranch(liveStatus: ownCode.liveStatus, hasLeaf: leaf != nil).flatMap { branch in
            switch branch {
            case .adHoc:
                return designatedRequirement(ofCodeAt: adHocFallback).map { TrustedPeer(requirement: $0, requiresHardenedRuntime: false) }
            case .certificate:
                guard let leaf else { return .failure(.ownSigningModeMismatch(runningAdHoc: false)) }
                return certificateRequirement(identifier: identifier, leaf: leaf)
            }
        }
    }

    private static func certificateRequirement(identifier: String, leaf: SecCertificate) -> Result<TrustedPeer, PeerVerificationError> {
        let leafHash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        let text = "identifier \"\(identifier)\" and certificate leaf = H\"\(leafHash)\""
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard created == errSecSuccess else { return .failure(.requirementUnbuildable(created)) }
        guard let requirement else { return .failure(.securityCallReturnedNothing("SecRequirementCreateWithString")) }
        return .success(TrustedPeer(requirement: requirement, requiresHardenedRuntime: true))
    }

    static func verify(
        socket: Int32,
        against trusted: TrustedPeer,
        statusReader: (SecCode) -> Result<UInt32, PeerVerificationError> = liveStatus(of:)
    ) -> Result<Void, PeerVerificationError> {
        peerCode(of: socket).flatMap { code in
            let status = SecCodeCheckValidity(code, [], trusted.requirement)
            guard status == errSecSuccess else { return .failure(.requirementNotSatisfied(status)) }
            guard trusted.requiresHardenedRuntime else { return .success(()) }
            return statusReader(code).flatMap { hardenedRuntimeCheck(codeStatus: $0, required: true) }
        }
    }

    // CS_GET_TASK_ALLOW and CS_DEBUGGED from the kernel's cs_blobs.h, which has no SDK constant.
    static let getTaskAllowFlag: UInt32 = 0x0000_0004
    static let debuggedFlag: UInt32 = 0x1000_0000

    static func hardenedRuntimeCheck(codeStatus: UInt32, required: Bool) -> Result<Void, PeerVerificationError> {
        guard required else { return .success(()) }
        guard codeStatus & SecCodeSignatureFlags.runtime.rawValue != 0 else { return .failure(.peerWithoutHardenedRuntime) }
        guard codeStatus & (getTaskAllowFlag | debuggedFlag) == 0 else { return .failure(.peerIsDebuggable) }
        return .success(())
    }

    // The running process's flags, not the file's: SecCode is a SecStaticCode subclass in the
    // Security framework, and kSecCSDynamicInformation makes the call read the live status.
    static func liveStatus(of code: SecCode) -> Result<UInt32, PeerVerificationError> {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSDynamicInformation), &info
        )
        guard status == errSecSuccess else { return .failure(.peerStatusUnavailable(status)) }
        return codeStatus(from: info as? [String: Any] ?? [:])
    }

    static func codeStatus(from signingInformation: [String: Any]) -> Result<UInt32, PeerVerificationError> {
        guard let status = signingInformation[kSecCodeInfoStatus as String] as? NSNumber else {
            return .failure(.securityCallReturnedNothing("kSecCodeInfoStatus"))
        }
        return .success(status.uint32Value)
    }

    /// Only for logging: the decision uses the audit token, which a reused PID cannot fake.
    static func peerProcessID(of socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    private static func designatedRequirement(ofCodeAt url: URL) -> Result<SecRequirement, PeerVerificationError> {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess else { return .failure(.expectedCodeUnavailable(path: url.path, status: status)) }
        guard let staticCode else { return .failure(.securityCallReturnedNothing("SecStaticCodeCreateWithPath")) }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess else { return .failure(.expectedCodeUnavailable(path: url.path, status: status)) }
        guard let requirement else { return .failure(.securityCallReturnedNothing("SecCodeCopyDesignatedRequirement")) }
        return .success(requirement)
    }

    private static func peerCode(of socket: Int32) -> Result<SecCode, PeerVerificationError> {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            return .failure(.peerTokenUnavailable(errno: errno))
        }
        guard length == MemoryLayout<audit_token_t>.size else { return .failure(.peerTokenUnavailable(errno: EINVAL)) }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess else { return .failure(.peerCodeUnavailable(status)) }
        guard let code else { return .failure(.securityCallReturnedNothing("SecCodeCopyGuestWithAttributes")) }
        return .success(code)
    }
}
