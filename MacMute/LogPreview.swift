import Foundation

private let previewLimit = 128

/// Bounds a peer-supplied string before it reaches the log, so a helper cannot flood it.
func preview(_ text: String) -> String {
    let bytes = text.utf8
    guard bytes.count > previewLimit else { return text }
    return String(decoding: bytes.prefix(previewLimit), as: UTF8.self) + "… (\(bytes.count) bytes)"
}

/// Describes a peer message by its keys, never its values.
func preview(_ message: [String: Any]) -> String {
    preview("keys=[\(message.keys.sorted().joined(separator: ", "))]")
}
