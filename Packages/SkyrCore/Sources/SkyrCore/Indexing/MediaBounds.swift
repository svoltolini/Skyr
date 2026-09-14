import Foundation

/// Checks lengths before addition or conversion when reading file-provided offsets.
nonisolated enum MediaBounds {
    static func contains(_ offset: Int, _ length: Int, end: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= end && length <= end - offset
    }

    static func range(_ offset: Int64, length: Int64) -> Range<Int64>? {
        guard offset >= 0, length >= 0, length <= Int64.max - offset else { return nil }
        return offset..<(offset + length)
    }

    static func positiveInteger(_ value: UInt64) -> Int? {
        guard value > 0 else { return nil }
        return Int(exactly: value)
    }

    static func bitrate(bytes: Int64, duration: Double) -> Int? {
        guard bytes >= 0, duration.isFinite, duration > 0 else { return nil }
        let value = Double(bytes) * 8 / duration
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
}
