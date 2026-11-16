import Foundation

private let previewLimit = 128

/// Bounds a peer-supplied string before it reaches the log, so a helper can neither flood it nor
/// forge lines in it.
func preview(_ text: String) -> String {
    let escaped = escapingControlCharacters(text)
    let bytes = escaped.utf8
    guard bytes.count > previewLimit else { return escaped }
    return String(decoding: bytes.prefix(previewLimit), as: UTF8.self) + "… (\(bytes.count) bytes)"
}

/// Describes a peer message by its keys and value types. Only `type` and `target` show their value.
func preview(_ message: [String: Any]) -> String {
    let fields = message.keys.sorted().map { key -> String in
        let value = message[key]!
        let described = "\(key):\(jsonTypeName(value))"
        guard ["type", "target"].contains(key), let text = value as? String else { return described }
        return "\(described)=\"\(text)\""
    }
    return preview(fields.joined(separator: ", "))
}

// Format characters include the bidi controls (U+202E, U+2066-2069) that can make a line read
// differently from what it contains.
private let escapedCategories: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]

private func escapingControlCharacters(_ text: String) -> String {
    var escaped = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if escapedCategories.contains(scalar.properties.generalCategory) {
            escaped.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
        } else {
            escaped.append(scalar)
        }
    }
    return String(escaped)
}

private func jsonTypeName(_ value: Any) -> String {
    switch value {
    case is String: return "String"
    case let number as NSNumber:
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? "Bool" : "Number"
    case is [Any]: return "Array"
    case is [String: Any]: return "Object"
    case is NSNull: return "Null"
    default: return String(describing: type(of: value))
    }
}
