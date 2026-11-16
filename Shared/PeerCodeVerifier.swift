import Foundation
import Security

enum PeerVerificationError: Error, Equatable {
    case expectedCodeUnavailable(OSStatus)
    case peerTokenUnavailable(errno: Int32)
    case peerCodeUnavailable(OSStatus)
    case requirementNotSatisfied(OSStatus)
}

/// Checks that the process at the other end of a Unix socket runs code signed like a sibling
/// binary on disk. Comparing designated requirements avoids hard-coding certificate hashes, so
/// the same check works for ad-hoc Debug builds and for the signed release.
enum PeerCodeVerifier {
    static func verify(socket: Int32, againstCodeAt url: URL) -> Result<Void, PeerVerificationError> {
        designatedRequirement(ofCodeAt: url).flatMap { verify(socket: socket, against: $0) }
    }

    static func verify(socket: Int32, against requirement: SecRequirement) -> Result<Void, PeerVerificationError> {
        peerCode(of: socket).flatMap { code in
            let status = SecCodeCheckValidity(code, [], requirement)
            return status == errSecSuccess ? .success(()) : .failure(.requirementNotSatisfied(status))
        }
    }

    private static func designatedRequirement(ofCodeAt url: URL) -> Result<SecRequirement, PeerVerificationError> {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return .failure(.expectedCodeUnavailable(status)) }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else { return .failure(.expectedCodeUnavailable(status)) }
        return .success(requirement)
    }

    // The audit token identifies the exact process that connected; a PID could be reused by
    // another process before the check runs.
    private static func peerCode(of socket: Int32) -> Result<SecCode, PeerVerificationError> {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            return .failure(.peerTokenUnavailable(errno: errno))
        }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else { return .failure(.peerCodeUnavailable(status)) }
        return .success(code)
    }
}
