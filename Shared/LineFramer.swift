import Foundation

/// Splits a byte stream into newline-delimited lines. A peer that never sends a newline would
/// otherwise make the buffer grow without bound, so a line longer than the limit is an error.
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
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            guard line.count <= maxLineLength else { throw LineTooLong(limit: maxLineLength) }
            lines.append(Data(line))
            pending = Data(pending[pending.index(after: newline)...])
        }
        guard pending.count <= maxLineLength else { throw LineTooLong(limit: maxLineLength) }
        return lines
    }
}
