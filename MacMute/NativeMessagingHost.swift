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
}
