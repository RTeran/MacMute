import Foundation

enum NativeMessagingHost {
    static let name = "com.macmute.helper"
    // Fixed by the "key" in chrome-extension/manifest.json; NativeMessagingHostTests checks they match.
    static let extensionID = "ealicgogcpkafcocpppnmhgcaiepdple"

    static func manifest(helperPath: String) -> [String: Any] {
        [
            "name": name,
            "description": "MacMute Native Messaging Helper",
            "path": helperPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
    }

    // .atomic renames a temporary file over the target, so a symlink planted there is replaced,
    // not followed, and a crash cannot leave a truncated manifest.
    static func install(helperPath: String, into directory: URL) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: manifest(helperPath: helperPath), options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("\(name).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
