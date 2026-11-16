import Foundation

struct HelperExecutability {
    let isExecutable: Bool
    let chmodError: Error?
}

// A bundle owned by another user or on a read-only volume (App Translocation, a DMG) refuses
// chmod, so the helper is only changed when it cannot already run.
func ensureExecutable(atPath path: String, fileManager: FileManager = .default) -> HelperExecutability {
    guard !fileManager.isExecutableFile(atPath: path) else {
        return HelperExecutability(isExecutable: true, chmodError: nil)
    }
    do {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return HelperExecutability(isExecutable: fileManager.isExecutableFile(atPath: path), chmodError: nil)
    } catch {
        return HelperExecutability(isExecutable: fileManager.isExecutableFile(atPath: path), chmodError: error)
    }
}
