import Foundation

enum NativeMessageReadResult {
    case message([String: Any])
    case skipped(String)
    case endOfInput
}

/// Reads Chrome native messaging frames: a 4-byte little-endian length, then that many bytes of JSON.
/// A bad frame is skipped instead of ending the helper, since only Chrome closing stdin means it is done.
struct NativeMessageReader {
    static let maxMessageLength = 1024 * 1024

    private let fileDescriptor: Int32
    private let chunkSize: Int

    init(fileDescriptor: Int32, chunkSize: Int = 64 * 1024) {
        self.fileDescriptor = fileDescriptor
        self.chunkSize = chunkSize
    }

    func next() -> NativeMessageReadResult {
        guard let header = readExactly(4) else { return .endOfInput }
        let length = Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= Self.maxMessageLength else {
            // Read in chunks so an oversized frame never has to fit in memory.
            guard discard(length) else { return .endOfInput }
            return .skipped("frame of \(length) bytes is over the \(Self.maxMessageLength) byte limit")
        }
        guard let body = readExactly(length) else { return .endOfInput }
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return .skipped("frame of \(length) bytes is not JSON")
        }
        guard let message = object as? [String: Any] else {
            return .skipped("frame of \(length) bytes is not a JSON object")
        }
        return .message(message)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let result = data.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress! + filled, count - filled) }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return nil }
            filled += result
        }
        return data
    }

    private func discard(_ count: Int) -> Bool {
        var remaining = count
        while remaining > 0 {
            guard let chunk = readExactly(min(chunkSize, remaining)) else { return false }
            remaining -= chunk.count
        }
        return true
    }
}
