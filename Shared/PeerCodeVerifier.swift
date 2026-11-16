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
        }
    }
}

/// Checks that the process at the other end of a Unix socket runs trusted code. The trusted
/// requirement is derived from signatures instead of hard-coded hashes, so the same check works
/// for ad-hoc Debug builds and for the signed release.
enum PeerCodeVerifier {
    /// Must match the identifier the helper is signed with (OTHER_CODE_SIGN_FLAGS and scripts/release.sh).
    static let helperIdentifier = "com.macmute.helper"

    /// The on-disk copy decides what is trusted, so it is used only after the running code has been
    /// checked against it. The checked SecCode keeps that copy, so replacing the file later changes nothing.
    static func ownStaticCode() -> Result<SecStaticCode, PeerVerificationError> {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { return .failure(.ownSignatureUnavailable(status)) }
        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { return .failure(.ownSignatureInvalid(status)) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return .failure(.ownSignatureUnavailable(status)) }
        return .success(staticCode)
    }

    /// With a certificate, the helper must carry `helperIdentifier` and be signed by the same leaf
    /// as `app`; the helper file is not read, so replacing it cannot change what is trusted.
    /// An ad-hoc app (Debug) has no certificate to compare with, so it trusts the designated
    /// requirement of the bundled helper as it is on disk now.
    static func trustedHelperRequirement(
        signedLike app: SecStaticCode, helperIdentifier: String, bundledHelper: URL
    ) -> Result<SecRequirement, PeerVerificationError> {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(app, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let info = info as? [String: Any] else {
            return .failure(.ownSignatureUnavailable(status))
        }
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            return designatedRequirement(ofCodeAt: bundledHelper)
        }
        let leafHash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        let text = "identifier \"\(helperIdentifier)\" and certificate leaf = H\"\(leafHash)\""
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard created == errSecSuccess, let requirement else { return .failure(.requirementUnbuildable(created)) }
        return .success(requirement)
    }

    static func verify(socket: Int32, against requirement: SecRequirement) -> Result<Void, PeerVerificationError> {
        peerCode(of: socket).flatMap { code in
            let status = SecCodeCheckValidity(code, [], requirement)
            return status == errSecSuccess ? .success(()) : .failure(.requirementNotSatisfied(status))
        }
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
        guard status == errSecSuccess, let staticCode else {
            return .failure(.expectedCodeUnavailable(path: url.path, status: status))
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            return .failure(.expectedCodeUnavailable(path: url.path, status: status))
        }
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
        guard status == errSecSuccess, let code else { return .failure(.peerCodeUnavailable(status)) }
        return .success(code)
    }
}
