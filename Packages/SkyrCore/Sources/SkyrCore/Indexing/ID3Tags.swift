import Foundation

/// Reads an MP3's ID3v2 tag and its first frame with one or two ranged reads: title, artist and the
/// rest from the tag, bitrate and sample rate from the frame header, and the duration from the Xing
/// header when there is one or from the file size otherwise.
public nonisolated enum ID3Tags {
    public static let headRead: Int64 = 64 * 1024
    public static let maximumTag: Int64 = 8 * 1024 * 1024

    public static func read(fileSize: Int64?, read: (Range<Int64>) async throws -> Data) async throws -> ProbedMedia? {
        var b = [UInt8](try await read(0..<headRead))
        guard b.count >= 4 else { return nil }
        var media = ProbedMedia()
        var audioStart = 0
        var hasTag = false
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            let major = b[3]
            guard major == 3 || major == 4 else { return nil }
            let flags = b[5]
            let size = syncsafe(b, 6)
            let total = 10 + size + (major == 4 && flags & 0x10 != 0 ? 10 : 0)
            guard Int64(total) <= maximumTag else { return nil }
            if total + 4096 > b.count {
                b = [UInt8](try await read(0..<Int64(total + 4096)))
            }
            guard total <= b.count else { return nil }
            parseFrames(b, major: major, tagFlags: flags, end: 10 + size, into: &media)
            audioStart = total
            hasTag = true
        }
        guard let frame = firstFrame(b, from: audioStart) else { return hasTag ? media : nil }
        media.codec = "mp3"
        media.sampleRate = frame.sampleRate
        let audioBytes = fileSize.map { $0 > Int64(audioStart) ? $0 - Int64(audioStart) : 0 }
        if let frames = frame.xingFrames, frame.sampleRate > 0 {
            let duration = Double(frames) * Double(frame.samplesPerFrame) / Double(frame.sampleRate)
            media.duration = duration
            if let audioBytes, duration > 0 {
                media.bitrate = MediaBounds.bitrate(bytes: audioBytes, duration: duration)
            }
        } else if frame.bitrate > 0 {
            media.bitrate = frame.bitrate
            if let audioBytes { media.duration = Double(audioBytes) * 8 / Double(frame.bitrate) }
        }
        return media
    }

    // MARK: Frames

    private static func parseFrames(_ b: [UInt8], major: UInt8, tagFlags: UInt8, end: Int, into media: inout ProbedMedia) {
        var position = 10
        if tagFlags & 0x40 != 0 {
            guard MediaBounds.contains(position, 4, end: end) else { return }
            // An extended header; its size counts itself in v2.4 and not in v2.3.
            let length = major == 4 ? syncsafe(b, position) : Int(MP4Tags.u32(b, position)) + 4
            guard length >= (major == 4 ? 6 : 10), MediaBounds.contains(position, length, end: end) else { return }
            position += length
        }
        while MediaBounds.contains(position, 10, end: end) {
            let id = String(bytes: b[position..<position + 4], encoding: .isoLatin1) ?? ""
            if b[position] == 0 { break }   // padding
            let size = major == 4 ? syncsafe(b, position + 4) : Int(MP4Tags.u32(b, position + 4))
            let frameFlags = Int(b[position + 8]) << 8 | Int(b[position + 9])
            let start = position + 10
            guard MediaBounds.contains(start, size, end: end) else { return }
            let frameEnd = start + size
            position = frameEnd
            guard size > 0 else { continue }
            let compressed = major == 4 ? frameFlags & 0x0008 != 0 : frameFlags & 0x0080 != 0
            let encrypted = major == 4 ? frameFlags & 0x0004 != 0 : frameFlags & 0x0040 != 0
            if compressed || encrypted { continue }
            var payload = Array(b[start..<frameEnd])
            if (major == 4 && frameFlags & 0x0002 != 0) || (major == 3 && tagFlags & 0x80 != 0) {
                payload = unsynchronised(payload)
            }
            let groupLength = (major == 3 ? frameFlags & 0x0020 : frameFlags & 0x0040) != 0 ? 1 : 0
            let indicatorLength = major == 4 && frameFlags & 0x0001 != 0 ? 4 : 0
            let prefixLength = groupLength + indicatorLength
            guard MediaBounds.contains(0, prefixLength, end: payload.count) else { continue }
            payload.removeFirst(prefixLength)
            switch id {
            case "TIT2": media.title = textFrame(payload)
            case "TPE1": media.artist = textFrame(payload)
            case "TALB": media.album = textFrame(payload)
            case "TPE2": media.albumArtist = textFrame(payload)
            case "TCON": media.genre = textFrame(payload).map(genreName)
            case "TYER", "TDRC", "TDOR":
                if media.year == nil, let text = textFrame(payload) { media.year = Int(text.prefix(4)) }
            case "TRCK": media.trackNumber = textFrame(payload).flatMap { Int($0.split(separator: "/").first ?? "") }
            case "TPOS": media.discNumber = textFrame(payload).flatMap { Int($0.split(separator: "/").first ?? "") }
            case "APIC":
                if media.artwork == nil, let picture = picture(payload) { media.artwork = picture }
            default: break
            }
        }
    }

    static func textFrame(_ payload: [UInt8]) -> String? {
        guard let first = payload.first else { return nil }
        let text = decode(Array(payload.dropFirst()), encoding: first)
        // v2.4 lists several values separated by NUL; the first is the one that matters.
        let value = text.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decode(_ bytes: [UInt8], encoding: UInt8) -> String {
        switch encoding {
        case 1:
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
            return String(bytes: bytes, encoding: .utf16LittleEndian) ?? ""
        case 2: return String(bytes: bytes, encoding: .utf16BigEndian) ?? ""
        case 3: return String(bytes: bytes, encoding: .utf8) ?? ""
        default: return String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
    }

    /// "(17)" and "17" are indexes into the ID3v1 list; anything else is already a name.
    static func genreName(_ raw: String) -> String {
        let digits = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if let index = Int(digits), index >= 0, index < MediaProbe.id3Genres.count { return MediaProbe.id3Genres[index] }
        return raw
    }

    private static func picture(_ payload: [UInt8]) -> Data? {
        guard payload.count > 4 else { return nil }
        let encoding = payload[0]
        var position = 1
        while position < payload.count, payload[position] != 0 { position += 1 }   // MIME type
        position += 2                                                             // NUL and picture type
        // The description ends with one NUL, or two for the wide encodings.
        if encoding == 1 || encoding == 2 {
            while position + 1 < payload.count, !(payload[position] == 0 && payload[position + 1] == 0) { position += 2 }
            position += 2
        } else {
            while position < payload.count, payload[position] != 0 { position += 1 }
            position += 1
        }
        guard position < payload.count else { return nil }
        return Data(payload[position...])
    }

    static func unsynchronised(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            result.append(bytes[index])
            if bytes[index] == 0xFF, index + 1 < bytes.count, bytes[index + 1] == 0 { index += 1 }
            index += 1
        }
        return result
    }

    static func syncsafe(_ b: [UInt8], _ at: Int) -> Int {
        guard MediaBounds.contains(at, 4, end: b.count) else { return 0 }
        return Int(b[at] & 0x7F) << 21 | Int(b[at + 1] & 0x7F) << 14 | Int(b[at + 2] & 0x7F) << 7 | Int(b[at + 3] & 0x7F)
    }

    // MARK: The first MPEG frame

    private struct Frame {
        let sampleRate: Int
        let bitrate: Int
        let samplesPerFrame: Int
        let xingFrames: Int?
    }

    private static let bitratesMPEG1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let bitratesMPEG2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    /// Whether an MPEG audio frame header follows `start`; the writers use it to make sure a .mp3 is one.
    static func hasMPEGFrame(_ b: [UInt8], from start: Int) -> Bool {
        firstFrame(b, from: start) != nil
    }

    private static func firstFrame(_ b: [UInt8], from start: Int) -> Frame? {
        guard MediaBounds.contains(start, 4, end: b.count) else { return nil }
        var position = start
        let limit = start + min(b.count - start - 4, 64 * 1024)
        while position <= limit {
            defer { position += 1 }
            guard b[position] == 0xFF, b[position + 1] & 0xE0 == 0xE0 else { continue }
            let versionBits = (b[position + 1] >> 3) & 0x03
            let layerBits = (b[position + 1] >> 1) & 0x03
            let bitrateIndex = Int(b[position + 2] >> 4)
            let rateIndex = Int((b[position + 2] >> 2) & 0x03)
            let channelMode = b[position + 3] >> 6
            guard versionBits != 1, layerBits == 1, bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3 else { continue }
            let isMPEG1 = versionBits == 3
            let rates: [Int] = isMPEG1 ? [44100, 48000, 32000] : versionBits == 2 ? [22050, 24000, 16000] : [11025, 12000, 8000]
            let bitrate = (isMPEG1 ? bitratesMPEG1 : bitratesMPEG2)[bitrateIndex] * 1000
            let mono = channelMode == 3
            let sideInfo = isMPEG1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
            var xingFrames: Int?
            let xing = position + 4 + sideInfo
            if xing + 12 <= b.count {
                let tag = MP4Tags.fourCC(b, xing)
                if tag == "Xing" || tag == "Info", MP4Tags.u32(b, xing + 4) & 0x01 != 0 {
                    xingFrames = Int(MP4Tags.u32(b, xing + 8))
                }
            }
            return Frame(sampleRate: rates[rateIndex], bitrate: bitrate, samplesPerFrame: isMPEG1 ? 1152 : 576, xingFrames: xingFrames)
        }
        return nil
    }
}
