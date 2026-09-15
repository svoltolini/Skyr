import Foundation

/// Reads an MPEG-4 audio file's tags and stream details from its `moov` atom with one or two ranged
/// reads, instead of letting AVFoundation fetch the file piecemeal. Covers .m4a, .mp4, .aac in an
/// MP4 container, and Apple Lossless.
public nonisolated enum MP4Tags {
    public static let headRead: Int64 = 64 * 1024
    /// `moov` carries the cover too, so it can be large; anything beyond this is not worth the wait.
    public static let maximumMoov: Int64 = 24 * 1024 * 1024

    /// `read` fetches a byte range of the file; it is asked for the head, then for `moov` if that lies elsewhere.
    public static func read(read: (Range<Int64>) async throws -> Data) async throws -> ProbedMedia? {
        let head = [UInt8](try await read(0..<headRead))
        guard head.count >= 12, fourCC(head, 4) == "ftyp" else { return nil }
        var position: Int64 = 0
        for _ in 0..<8 {
            // The atom header at `position`: from the head when it is there, otherwise one small read.
            let header: [UInt8]
            guard let headerRange = MediaBounds.range(position, length: 16) else { return nil }
            if let offset = Int(exactly: position), MediaBounds.contains(offset, 16, end: head.count) {
                header = Array(head[offset..<offset + 16])
            } else {
                header = [UInt8](try await read(headerRange))
            }
            guard header.count >= 8 else { return nil }
            var size = Int64(u32(header, 0))
            var headerLength: Int64 = 8
            let type = fourCC(header, 4)
            if size == 1 {
                guard header.count >= 16 else { return nil }
                guard let extendedSize = Int64(exactly: u64(header, 8)) else { return nil }
                size = extendedSize
                headerLength = 16
            }
            guard size == 0 || size >= headerLength else { return nil }
            if type == "moov" {
                // A size of zero extends to EOF. One extra byte distinguishes a complete bounded
                // atom from a prefix; declared-size atoms must fit and arrive in full.
                guard size <= maximumMoov else { return nil }
                let length = size == 0 ? maximumMoov + 1 : size
                guard let range = MediaBounds.range(position, length: length) else { return nil }
                let moov: [UInt8]
                if let offset = Int(exactly: position), let count = Int(exactly: length),
                   MediaBounds.contains(offset, count, end: head.count) {
                    moov = Array(head[offset..<offset + count])
                } else {
                    moov = [UInt8](try await read(range))
                }
                guard moov.count >= headerLength, moov.count <= maximumMoov,
                      size == 0 || moov.count == size else { return nil }
                return parseMoov(moov, from: Int(headerLength))
            }
            guard size > 0, let range = MediaBounds.range(position, length: size) else { return nil }
            position = range.upperBound
        }
        return nil
    }

    // MARK: moov

    private static func parseMoov(_ b: [UInt8], from start: Int) -> ProbedMedia? {
        var media = ProbedMedia()
        var movieTimescale = 0
        var movieDuration: Int64 = 0
        var found = false
        for (type, payload, end) in boxes(b, start, b.count) {
            switch type {
            case "mvhd":
                guard MediaBounds.contains(payload, 1, end: end) else { continue }
                let version = b[payload]
                if version == 1, MediaBounds.contains(payload, 32, end: end),
                   let duration = Int64(exactly: u64(b, payload + 24)) {
                    movieTimescale = Int(u32(b, payload + 20))
                    movieDuration = duration
                    found = true
                } else if version == 0, MediaBounds.contains(payload, 20, end: end) {
                    movieTimescale = Int(u32(b, payload + 12))
                    movieDuration = Int64(u32(b, payload + 16))
                    found = true
                }
            case "trak":
                found = parseTrack(b, payload, end, into: &media) || found
            case "udta":
                for (childType, childPayload, childEnd) in boxes(b, payload, end) where childType == "meta" {
                    parseMeta(b, childPayload, childEnd, into: &media)
                }
            case "meta":
                parseMeta(b, payload, end, into: &media)
            default:
                break
            }
        }
        if media.duration == nil, movieTimescale > 0, movieDuration > 0 {
            media.duration = Double(movieDuration) / Double(movieTimescale)
        }
        return found ? media : nil
    }

    private static func parseTrack(_ b: [UInt8], _ start: Int, _ end: Int, into media: inout ProbedMedia) -> Bool {
        guard let mdia = boxes(b, start, end).first(where: { $0.0 == "mdia" }) else { return false }
        var isAudio = false
        var timescale = 0
        var duration: Int64 = 0
        for (type, payload, boxEnd) in boxes(b, mdia.1, mdia.2) {
            switch type {
            case "hdlr":
                if MediaBounds.contains(payload, 12, end: boxEnd) { isAudio = fourCC(b, payload + 8) == "soun" }
            case "mdhd":
                guard MediaBounds.contains(payload, 1, end: boxEnd) else { continue }
                let version = b[payload]
                if version == 1, MediaBounds.contains(payload, 32, end: boxEnd),
                   let value = Int64(exactly: u64(b, payload + 24)) {
                    timescale = Int(u32(b, payload + 20))
                    duration = value
                } else if version == 0, MediaBounds.contains(payload, 20, end: boxEnd) {
                    timescale = Int(u32(b, payload + 12))
                    duration = Int64(u32(b, payload + 16))
                }
            case "minf":
                guard let stbl = boxes(b, payload, boxEnd).first(where: { $0.0 == "stbl" }),
                      let stsd = boxes(b, stbl.1, stbl.2).first(where: { $0.0 == "stsd" }) else { continue }
                parseSampleDescriptions(b, stsd.1, stsd.2, into: &media)
            default:
                break
            }
        }
        guard isAudio || media.codec != nil else { return false }
        if timescale > 0, duration > 0 { media.duration = Double(duration) / Double(timescale) }
        return true
    }

    /// The first audio sample entry: codec, sample rate, channels, and for ALAC the bit depth.
    private static func parseSampleDescriptions(_ b: [UInt8], _ start: Int, _ end: Int, into media: inout ProbedMedia) {
        guard MediaBounds.contains(start, 8, end: end) else { return }
        for (type, payload, boxEnd) in boxes(b, start + 8, end) {
            switch type {
            case "mp4a", "alac", "fLaC", "Opus", ".mp3":
                guard MediaBounds.contains(payload, 28, end: boxEnd) else { return }
                let version = Int(u16(b, payload + 8))
                let channels = Int(u16(b, payload + 16))
                let sampleSize = Int(u16(b, payload + 18))
                let sampleRate = Int(u32(b, payload + 24) >> 16)
                if sampleRate > 0 { media.sampleRate = sampleRate }
                _ = channels
                let childrenStart = payload + 28 + (version == 1 ? 16 : version == 2 ? 36 : 0)
                switch type {
                case "mp4a":
                    media.codec = "aac"
                    for (childType, childPayload, childEnd) in boxes(b, childrenStart, boxEnd) where childType == "esds" {
                        guard MediaBounds.contains(childPayload, 4, end: childEnd) else { continue }
                        if let (objectType, bitrate) = parseESDS(b, childPayload + 4, childEnd) {
                            if bitrate > 0 { media.bitrate = bitrate }
                            if objectType == 0x69 || objectType == 0x6B { media.codec = "mp3" }
                        }
                    }
                case "alac":
                    media.codec = "alac"
                    for (childType, childPayload, childEnd) in boxes(b, childrenStart, boxEnd) where childType == "alac" {
                        // The ALAC magic cookie: frame length, version, bit depth, pb, mb, kb, channels,
                        // max run, max frame bytes, average bitrate, sample rate.
                        guard MediaBounds.contains(childPayload, 28, end: childEnd) else { continue }
                        let cookie = childPayload + 4
                        let depth = Int(b[cookie + 5])
                        if depth > 0 { media.bitsPerChannel = depth }
                        let average = Int(u32(b, cookie + 16))
                        if average > 0 { media.bitrate = average }
                        let rate = Int(u32(b, cookie + 20))
                        if rate > 0 { media.sampleRate = rate }
                    }
                case "fLaC":
                    media.codec = "flac"
                    if sampleSize > 0 { media.bitsPerChannel = sampleSize }
                case "Opus":
                    media.codec = "opus"
                default:
                    media.codec = "mp3"
                }
                return
            default:
                continue
            }
        }
    }

    /// The elementary stream descriptor: the object type says AAC or MP3, and the average bitrate is here.
    private static func parseESDS(_ b: [UInt8], _ start: Int, _ end: Int) -> (Int, Int)? {
        guard MediaBounds.contains(start, 0, end: end), end <= b.count else { return nil }
        func descriptor(_ tag: UInt8, at offset: Int, limit: Int) -> Range<Int>? {
            guard MediaBounds.contains(offset, 2, end: limit), b[offset] == tag else { return nil }
            var position = offset + 1
            var size = 0
            for _ in 0..<4 {
                guard position < limit else { return nil }
                let byte = Int(b[position])
                position += 1
                size = size << 7 | (byte & 0x7F)
                if byte & 0x80 == 0 {
                    guard MediaBounds.contains(position, size, end: limit) else { return nil }
                    return position..<position + size
                }
            }
            return nil
        }
        guard let es = descriptor(0x03, at: start, limit: end), es.count >= 3 else { return nil }
        let flags = b[es.lowerBound + 2]
        var position = es.lowerBound + 3
        func consume(_ length: Int) -> Bool {
            guard MediaBounds.contains(position, length, end: es.upperBound) else { return false }
            position += length
            return true
        }
        if flags & 0x80 != 0, !consume(2) { return nil }
        if flags & 0x40 != 0 {
            guard position < es.upperBound else { return nil }
            let length = Int(b[position])
            guard consume(1 + length) else { return nil }
        }
        if flags & 0x20 != 0, !consume(2) { return nil }
        guard let config = descriptor(0x04, at: position, limit: es.upperBound), config.count >= 13 else { return nil }
        let objectType = Int(b[config.lowerBound])
        let average = Int(u32(b, config.lowerBound + 9))
        return (objectType, average)
    }

    // MARK: Tags

    private static func parseMeta(_ b: [UInt8], _ start: Int, _ end: Int, into media: inout ProbedMedia) {
        // `meta` is a full box: four bytes of version and flags before its children.
        guard MediaBounds.contains(start, 4, end: end),
              let ilst = boxes(b, start + 4, end).first(where: { $0.0 == "ilst" }) else { return }
        for (item, payload, itemEnd) in boxes(b, ilst.1, ilst.2) {
            guard let data = boxes(b, payload, itemEnd).first(where: { $0.0 == "data" }),
                  MediaBounds.contains(data.1, 8, end: data.2) else { continue }
            let kind = Int(u32(b, data.1)) & 0x00FF_FFFF
            let value = Array(b[(data.1 + 8)..<data.2])
            func text() -> String? {
                let string = kind == 1 ? String(bytes: value, encoding: .utf8) : String(bytes: value, encoding: .isoLatin1)
                let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            switch item {
            case "\u{A9}nam": media.title = text()
            case "\u{A9}ART": media.artist = text()
            case "\u{A9}alb": media.album = text()
            case "aART": media.albumArtist = text()
            case "\u{A9}gen": media.genre = text()
            case "gnre":
                if value.count >= 2 {
                    let index = Int(value[value.count - 2]) << 8 | Int(value[value.count - 1])
                    if index >= 1, index <= MediaProbe.id3Genres.count, media.genre == nil { media.genre = MediaProbe.id3Genres[index - 1] }
                }
            case "\u{A9}day":
                if let year = text().flatMap({ Int($0.prefix(4)) }) { media.year = year }
            case "trkn":
                media.trackNumber = number(value, kind: kind)
            case "disk":
                media.discNumber = number(value, kind: kind)
            case "covr":
                if media.artwork == nil, !value.isEmpty { media.artwork = Data(value) }
            default:
                break
            }
        }
    }

    /// iTunes packs "3 of 12" into eight bytes with the number at bytes two and three; other writers
    /// store a plain big-endian integer of one, two, four or eight bytes.
    private static func number(_ value: [UInt8], kind: Int) -> Int? {
        if kind == 21 || kind == 22 || value.count == 1 {
            guard !value.isEmpty, value.count <= 8 else { return nil }
            return MediaBounds.positiveInteger(value.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        guard value.count >= 4 else { return nil }
        let result = Int(value[2]) << 8 | Int(value[3])
        return result > 0 ? result : nil
    }

    // MARK: Bytes

    /// The child boxes between two offsets: type, payload start, box end.
    static func boxes(_ b: [UInt8], _ start: Int, _ end: Int) -> [(String, Int, Int)] {
        guard MediaBounds.contains(start, 0, end: end), end <= b.count else { return [] }
        var result: [(String, Int, Int)] = []
        var position = start
        while MediaBounds.contains(position, 8, end: end) {
            var size = Int(u32(b, position))
            let type = fourCC(b, position + 4)
            var headerLength = 8
            if size == 1 {
                guard MediaBounds.contains(position, 16, end: end),
                      let extendedSize = Int(exactly: u64(b, position + 8)) else { break }
                size = extendedSize
                headerLength = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerLength, MediaBounds.contains(position, size, end: end) else { break }
            result.append((type, position + headerLength, position + size))
            position += size
        }
        return result
    }

    static func fourCC(_ b: [UInt8], _ at: Int) -> String {
        guard MediaBounds.contains(at, 4, end: b.count) else { return "" }
        return String(bytes: b[at..<at + 4], encoding: .isoLatin1) ?? ""
    }

    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        guard MediaBounds.contains(at, 2, end: b.count) else { return 0 }
        return UInt16(b[at]) << 8 | UInt16(b[at + 1])
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard MediaBounds.contains(at, 4, end: b.count) else { return 0 }
        return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        guard MediaBounds.contains(at, 8, end: b.count) else { return 0 }
        return UInt64(u32(b, at)) << 32 | UInt64(u32(b, at + 4))
    }
}
