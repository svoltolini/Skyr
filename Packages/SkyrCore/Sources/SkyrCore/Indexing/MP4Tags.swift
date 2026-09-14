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
            if Int(position) + 16 <= head.count {
                header = Array(head[Int(position)..<Int(position) + 16])
            } else {
                header = [UInt8](try await read(position..<position + 16))
            }
            guard header.count >= 8 else { return nil }
            var size = Int64(u32(header, 0))
            var headerLength: Int64 = 8
            let type = fourCC(header, 4)
            if size == 1 {
                guard header.count >= 16 else { return nil }
                size = Int64(u64(header, 8))
                headerLength = 16
            } else if size == 0 {
                size = Int64.max
            }
            if type == "moov" {
                let length = size == Int64.max ? maximumMoov : min(size, maximumMoov)
                let moov: [UInt8]
                if Int(position + length) <= head.count {
                    moov = Array(head[Int(position)..<Int(position + length)])
                } else {
                    moov = [UInt8](try await read(position..<position + length))
                }
                return parseMoov(moov, from: Int(headerLength))
            }
            guard size > 0, size != Int64.max else { return nil }
            position += size
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
                let version = b[payload]
                if version == 1, payload + 32 <= end {
                    movieTimescale = Int(u32(b, payload + 20))
                    movieDuration = Int64(u64(b, payload + 24))
                } else if payload + 24 <= end {
                    movieTimescale = Int(u32(b, payload + 12))
                    movieDuration = Int64(u32(b, payload + 16))
                }
                found = true
            case "trak":
                parseTrack(b, payload, end, into: &media)
                found = true
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

    private static func parseTrack(_ b: [UInt8], _ start: Int, _ end: Int, into media: inout ProbedMedia) {
        guard let mdia = boxes(b, start, end).first(where: { $0.0 == "mdia" }) else { return }
        var isAudio = false
        var timescale = 0
        var duration: Int64 = 0
        for (type, payload, boxEnd) in boxes(b, mdia.1, mdia.2) {
            switch type {
            case "hdlr":
                if payload + 12 <= boxEnd { isAudio = fourCC(b, payload + 8) == "soun" }
            case "mdhd":
                let version = b[payload]
                if version == 1, payload + 32 <= boxEnd {
                    timescale = Int(u32(b, payload + 20))
                    duration = Int64(u64(b, payload + 24))
                } else if payload + 24 <= boxEnd {
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
        guard isAudio || media.codec != nil else { return }
        if timescale > 0, duration > 0 { media.duration = Double(duration) / Double(timescale) }
    }

    /// The first audio sample entry: codec, sample rate, channels, and for ALAC the bit depth.
    private static func parseSampleDescriptions(_ b: [UInt8], _ start: Int, _ end: Int, into media: inout ProbedMedia) {
        guard start + 8 <= end else { return }
        for (type, payload, boxEnd) in boxes(b, start + 8, end) {
            switch type {
            case "mp4a", "alac", "fLaC", "Opus", ".mp3":
                guard payload + 28 <= boxEnd else { return }
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
                        let cookie = childPayload + 4
                        guard cookie + 24 <= childEnd else { continue }
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
        var position = start
        func expandableSize() -> Int? {
            var size = 0
            for _ in 0..<4 {
                guard position < end else { return nil }
                let byte = Int(b[position])
                position += 1
                size = size << 7 | (byte & 0x7F)
                if byte & 0x80 == 0 { return size }
            }
            return size
        }
        guard position < end, b[position] == 0x03 else { return nil }
        position += 1
        guard expandableSize() != nil, position + 3 <= end else { return nil }
        position += 2
        let flags = b[position]
        position += 1
        if flags & 0x80 != 0 { position += 2 }
        if flags & 0x40 != 0 {
            guard position < end else { return nil }
            position += 1 + Int(b[position])
        }
        if flags & 0x20 != 0 { position += 2 }
        guard position < end, b[position] == 0x04 else { return nil }
        position += 1
        guard expandableSize() != nil, position + 13 <= end else { return nil }
        let objectType = Int(b[position])
        let average = Int(u32(b, position + 9))
        return (objectType, average)
    }

    // MARK: Tags

    private static func parseMeta(_ b: [UInt8], _ start: Int, _ end: Int, into media: inout ProbedMedia) {
        // `meta` is a full box: four bytes of version and flags before its children.
        guard let ilst = boxes(b, start + 4, end).first(where: { $0.0 == "ilst" }) else { return }
        for (item, payload, itemEnd) in boxes(b, ilst.1, ilst.2) {
            guard let data = boxes(b, payload, itemEnd).first(where: { $0.0 == "data" }), data.1 + 8 <= data.2 else { continue }
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
            let result = value.reduce(0) { $0 << 8 | Int($1) }
            return result > 0 ? result : nil
        }
        guard value.count >= 4 else { return nil }
        let result = Int(value[2]) << 8 | Int(value[3])
        return result > 0 ? result : nil
    }

    // MARK: Bytes

    /// The child boxes between two offsets: type, payload start, box end.
    private static func boxes(_ b: [UInt8], _ start: Int, _ end: Int) -> [(String, Int, Int)] {
        var result: [(String, Int, Int)] = []
        var position = start
        while position + 8 <= end {
            var size = Int(u32(b, position))
            let type = fourCC(b, position + 4)
            var headerLength = 8
            if size == 1 {
                guard position + 16 <= end else { break }
                size = Int(u64(b, position + 8))
                headerLength = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerLength else { break }
            result.append((type, position + headerLength, min(position + size, end)))
            position += size
        }
        return result
    }

    static func fourCC(_ b: [UInt8], _ at: Int) -> String {
        guard at + 4 <= b.count else { return "" }
        return String(bytes: b[at..<at + 4], encoding: .isoLatin1) ?? ""
    }

    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= b.count else { return 0 }
        return UInt16(b[at]) << 8 | UInt16(b[at + 1])
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= b.count else { return 0 }
        return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        guard at + 8 <= b.count else { return 0 }
        return UInt64(u32(b, at)) << 32 | UInt64(u32(b, at + 4))
    }
}
