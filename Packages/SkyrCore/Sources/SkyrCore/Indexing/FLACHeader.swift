import Foundation

/// What the metadata blocks at the start of a FLAC file tell us.
public nonisolated struct FLACInfo: Sendable {
    public var sampleRate: Int?
    public var channels: Int?
    public var bitsPerSample: Int?
    public var totalSamples: Int64?
    /// Vorbis comment fields with uppercased keys, e.g. "TITLE", "TRACKNUMBER".
    public var tags: [String: String] = [:]
    public var picture: Data?
    public var pictureMIME: String?
    /// When the buffer ended inside a block, the prefix length that would contain it.
    public var neededPrefix: Int?

    public var duration: TimeInterval? {
        guard let totalSamples, let sampleRate, sampleRate > 0, totalSamples > 0 else { return nil }
        return Double(totalSamples) / Double(sampleRate)
    }

    public func tag(_ key: String) -> String? {
        guard let value = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// "3", "3/12" and "03" all become 3.
    public func number(_ key: String) -> Int? {
        guard let raw = tag(key) else { return nil }
        return Int(raw.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    public var year: Int? {
        guard let raw = tag("DATE") ?? tag("YEAR") ?? tag("ORIGINALDATE") else { return nil }
        return Int(raw.prefix(4))
    }
}

/// Parses FLAC metadata blocks from a prefix of the file.
public nonisolated enum FLACHeader {
    public static let initialRead: Int64 = 256 * 1024
    public static let maximumRead: Int64 = 8 * 1024 * 1024

    public static func parse(_ data: Data) -> FLACInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else { return nil }
        var info = FLACInfo()
        var offset = 4
        var pictureType: Int?
        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let isLast = header & 0x80 != 0
            let type = Int(header & 0x7F)
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            let end = start + length
            if end > bytes.count {
                // Skip a picture we don't need; otherwise ask for a longer prefix.
                if type == 6, info.picture != nil {
                    offset = end
                    if isLast { break } else { continue }
                }
                info.neededPrefix = end
                break
            }
            let block = Array(bytes[start..<end])
            switch type {
            case 0 where block.count >= 18:
                info.sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12] >> 4)
                info.channels = Int((block[12] >> 1) & 0x07) + 1
                info.bitsPerSample = Int((block[12] & 0x01) << 4 | (block[13] >> 4)) + 1
                info.totalSamples = Int64(block[13] & 0x0F) << 32 | Int64(block[14]) << 24 | Int64(block[15]) << 16 | Int64(block[16]) << 8 | Int64(block[17])
            case 4:
                info.tags.merge(parseVorbisComments(block)) { _, new in new }
            case 6:
                if let (kind, mime, picture) = parsePicture(block) {
                    // Prefer the front cover (type 3) over any other picture.
                    if info.picture == nil || (kind == 3 && pictureType != 3) {
                        info.picture = picture
                        info.pictureMIME = mime
                        pictureType = kind
                    }
                }
            default:
                break
            }
            offset = end
            if isLast { break }
        }
        return info
    }

    private static func parseVorbisComments(_ block: [UInt8]) -> [String: String] {
        var tags: [String: String] = [:]
        var offset = 0
        func readUInt32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) | Int(block[offset + 1]) << 8 | Int(block[offset + 2]) << 16 | Int(block[offset + 3]) << 24
            offset += 4
            return value
        }
        guard let vendorLength = readUInt32(), offset + vendorLength <= block.count else { return tags }
        offset += vendorLength
        guard let count = readUInt32() else { return tags }
        for _ in 0..<count {
            guard let length = readUInt32(), offset + length <= block.count else { break }
            let comment = String(decoding: block[offset..<offset + length], as: UTF8.self)
            offset += length
            guard let equals = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<equals].uppercased()
            let value = String(comment[comment.index(after: equals)...])
            if tags[key] == nil { tags[key] = value }
        }
        return tags
    }

    private static func parsePicture(_ block: [UInt8]) -> (Int, String, Data)? {
        var offset = 0
        func readUInt32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) << 24 | Int(block[offset + 1]) << 16 | Int(block[offset + 2]) << 8 | Int(block[offset + 3])
            offset += 4
            return value
        }
        guard let kind = readUInt32(), let mimeLength = readUInt32(), offset + mimeLength <= block.count else { return nil }
        let mime = String(decoding: block[offset..<offset + mimeLength], as: UTF8.self)
        offset += mimeLength
        guard let descriptionLength = readUInt32(), offset + descriptionLength <= block.count else { return nil }
        offset += descriptionLength
        guard offset + 16 <= block.count else { return nil }
        offset += 16
        guard let dataLength = readUInt32(), dataLength > 0, offset + dataLength <= block.count else { return nil }
        return (kind, mime, Data(block[offset..<offset + dataLength]))
    }
}
