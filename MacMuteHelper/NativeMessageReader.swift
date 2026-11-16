import Foundation

enum NativeMessageReadResult {
    case message([String: Any])
    case skipped(String)
    /// Chrome closed stdin between frames.
    case endOfInput
    /// Chrome closed stdin partway through a frame.
    case truncated(missingBytes: Int)
    case readFailed(errno: Int32)
}

/// Reads Chrome native messaging frames: a 4-byte little-endian length, then that many bytes of JSON.
/// A bad frame is skipped instead of ending the helper, since only Chrome closing stdin means it is done.
struct NativeMessageReader {
    static let maxMessageLength = 1024 * 1024

    private enum ReadOutcome {
        case complete(Data)
        case ended(missing: Int)
        case failed(errno: Int32)
    }

    private let fileDescriptor: Int32
    private let chunkSize: Int

    init(fileDescriptor: Int32, chunkSize: Int = 64 * 1024) {
        self.fileDescriptor = fileDescriptor
        self.chunkSize = chunkSize
    }

    func next() -> NativeMessageReadResult {
        let header: Data
        switch readExactly(4) {
        case let .complete(data): header = data
        case .ended(missing: 4): return .endOfInput
        case let .ended(missing): return .truncated(missingBytes: missing)
        case let .failed(code): return .readFailed(errno: code)
        }
        let length = Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= Self.maxMessageLength else {
            // Read in chunks so an oversized frame never has to fit in memory.
            return discard(length) ?? .skipped("frame of \(length) bytes is over the \(Self.maxMessageLength) byte limit")
        }
        let body: Data
        switch readExactly(length) {
        case let .complete(data): body = data
        case let .ended(missing): return .truncated(missingBytes: missing)
        case let .failed(code): return .readFailed(errno: code)
        }
        guard !body.isEmpty else { return .skipped("empty frame") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: body)
        } catch {
            return .skipped("frame of \(length) bytes is not JSON: \(Self.parserMessage(error))")
        }
        guard let message = object as? [String: Any] else {
            return .skipped("frame of \(length) bytes is not a JSON object")
        }
        return .message(message)
    }

    private func readExactly(_ count: Int) -> ReadOutcome {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let result = data.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress! + filled, count - filled) }
            if result < 0 {
                if errno == EINTR { continue }
                return .failed(errno: errno)
            }
            guard result > 0 else { return .ended(missing: count - filled) }
            filled += result
        }
        return .complete(data)
    }

    private func discard(_ count: Int) -> NativeMessageReadResult? {
        var remaining = count
        while remaining > 0 {
            let chunk = min(chunkSize, remaining)
            switch readExactly(chunk) {
            case .complete: remaining -= chunk
            case let .ended(missing): return .truncated(missingBytes: remaining - chunk + missing)
            case let .failed(code): return .readFailed(errno: code)
            }
        }
        return nil
    }

    // The debug description names the position of the problem without quoting the frame.
    private static func parserMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? "\(nsError.domain) \(nsError.code)"
    }
}
