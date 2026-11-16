import Foundation

/// Splits a byte stream into newline-delimited lines. A peer that never sends a newline would
/// otherwise make the buffer grow without bound, so a line longer than the limit is an error.
/// Empty lines carry no message and are skipped.
struct LineFramer {
    struct LineTooLong: Error, Equatable {
        let limit: Int
    }

    static let defaultMaxLineLength = 64 * 1024
    let maxLineLength: Int
    private var pending = Data()

    init(maxLineLength: Int = defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            let line = pending[lineStart..<newline]
            guard line.count <= maxLineLength else { throw LineTooLong(limit: maxLineLength) }
            if !line.isEmpty { lines.append(Data(line)) }
            lineStart = pending.index(after: newline)
        }
        pending = Data(pending[lineStart...])
        guard pending.count <= maxLineLength else { throw LineTooLong(limit: maxLineLength) }
        return lines
    }
}
