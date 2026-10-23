import Foundation

/// Which bytes of a file are on disk: sorted ranges that neither overlap nor touch.
public struct ByteRanges: Codable, Sendable, Equatable {
    public private(set) var ranges: [Range<Int64>] = []

    public init() {}

    /// Bytes held in all.
    public var count: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    public mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound, upper = range.upperBound
        var kept: [Range<Int64>] = []
        for held in ranges {
            if held.upperBound < lower || held.lowerBound > upper {
                kept.append(held)
            } else {
                // Overlapping or touching: one range from then on.
                lower = min(lower, held.lowerBound)
                upper = max(upper, held.upperBound)
            }
        }
        kept.append(lower..<upper)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// How many bytes from `offset` on are held without a gap.
    public func contiguousLength(from offset: Int64) -> Int64 {
        guard let held = ranges.first(where: { $0.contains(offset) }) else { return 0 }
        return held.upperBound - offset
    }

    public func contains(_ range: Range<Int64>) -> Bool {
        range.isEmpty || contiguousLength(from: range.lowerBound) >= range.upperBound - range.lowerBound
    }

    /// The first missing byte at or after `offset`, if one is before `end`.
    public func firstMissing(from offset: Int64 = 0, before end: Int64) -> Int64? {
        let missing = offset + contiguousLength(from: offset)
        return missing < end ? missing : nil
    }

    /// Where a gap starting at the missing byte `offset` ends: the next held range, or `end`.
    public func gapEnd(from offset: Int64, before end: Int64) -> Int64 {
        min(ranges.first { $0.lowerBound > offset }?.lowerBound ?? end, end)
    }
}
