import Foundation

/// Rewrites an MP3's ID3v2 tag with new values for a few text frames, copying every other frame
/// byte for byte, and keeps an ID3v1 tag at the end of the file in step. The tag keeps its version
/// (v2.3 or v2.4) and, whenever the new frames fit, its exact size, so the audio never moves.
nonisolated enum ID3TagWriter {
    private static let albumFrame = "TALB"
    private static let genreFrame = "TCON"
    /// Room left after the frames when the tag has to grow, so the next edit fits without moving the audio again.
    static let growthPadding = 1024

    struct Frame: Equatable {
        var id: String
        var flags: UInt16
        /// The frame's data exactly as stored, including any group byte or data length indicator.
        var payload: [UInt8]
    }

    struct ParsedTag {
        var major: UInt8
        var revision: UInt8
        var frames: [Frame]
        /// Bytes the tag occupies at the start of the file, footer included; zero when the file has none.
        var length: Int
    }

    static func plan(edits: TagEdits, fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> TagRewrite? {
        let head = [UInt8](try read(0..<min(fileSize, ID3Tags.headRead)))
        var tag: ParsedTag
        if let existing = try parseTag(head: head, fileSize: fileSize, read: read) {
            tag = existing
        } else {
            guard ID3Tags.hasMPEGFrame(head, from: 0) else { throw TagWriteError.mismatchedContents("no MPEG audio frame found") }
            // A file without a tag gets a v2.3 one, the version every player reads.
            tag = ParsedTag(major: 3, revision: 0, frames: [], length: 0)
        }
        var changed = false
        if let genre = edits.genre {
            let current = tag.frames.first { $0.id == genreFrame }.flatMap { text(of: $0, major: tag.major) }.map(ID3Tags.genreName)
            if current != genre {
                replace(genreFrame, with: genre, in: &tag)
                changed = true
            }
        }
        let currentAlbum = tag.frames.first { $0.id == albumFrame }.flatMap { text(of: $0, major: tag.major) }
        if let album = edits.albumValue(replacing: currentAlbum), album != currentAlbum {
            replace(albumFrame, with: album, in: &tag)
            changed = true
        }
        guard changed else { return nil }
        let audioStart = Int64(tag.length)
        var segments: [FileSegment] = [.bytes(try serialise(tag))]
        if fileSize - 128 >= audioStart, let tail = try patchedID3v1(edits: edits, fileSize: fileSize, read: read) {
            segments.append(.copy(audioStart..<fileSize - 128))
            segments.append(.bytes(tail))
        } else {
            segments.append(.copy(audioStart..<fileSize))
        }
        return TagRewrite(segments: segments)
    }

    // MARK: Parsing

    static func parseTag(head: [UInt8], fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> ParsedTag? {
        guard head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return nil }
        let major = head[3]
        guard major == 3 || major == 4 else { throw TagWriteError.unsupportedTagVersion(Int(major)) }
        let flags = head[5]
        let size = ID3Tags.syncsafe(head, 6)
        let hasFooter = major == 4 && flags & 0x10 != 0
        let total = 10 + size + (hasFooter ? 10 : 0)
        guard Int64(total) <= ID3Tags.maximumTag else { throw TagWriteError.tooLarge }
        guard Int64(total) <= fileSize else { throw TagWriteError.malformed("the tag runs past the end of the file") }
        let bytes = total <= head.count ? Array(head[0..<total]) : [UInt8](try read(0..<Int64(total)))
        guard bytes.count == total else { throw TagWriteError.malformed("the tag could not be read in full") }
        var body = Array(bytes[10..<10 + size])
        // v2.3 unsynchronises the whole tag at once; undone here, the frames are stored plainly again.
        if major == 3, flags & 0x80 != 0 { body = ID3Tags.unsynchronised(body) }
        var position = 0
        if flags & 0x40 != 0 {
            // The extended header is dropped on output: its CRC and padding count would be stale.
            guard MediaBounds.contains(position, 4, end: body.count) else { throw TagWriteError.malformed("extended header") }
            let length = major == 4 ? ID3Tags.syncsafe(body, position) : Int(MP4Tags.u32(body, position)) + 4
            guard length >= (major == 4 ? 6 : 10), MediaBounds.contains(position, length, end: body.count) else {
                throw TagWriteError.malformed("extended header")
            }
            position += length
        }
        var frames: [Frame] = []
        while MediaBounds.contains(position, 10, end: body.count) {
            if body[position] == 0 { break }   // padding
            let idBytes = body[position..<position + 4]
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else {
                throw TagWriteError.malformed("unexpected frame id")
            }
            let id = String(decoding: idBytes, as: UTF8.self)
            let frameSize = major == 4 ? ID3Tags.syncsafe(body, position + 4) : Int(MP4Tags.u32(body, position + 4))
            let frameFlags = UInt16(body[position + 8]) << 8 | UInt16(body[position + 9])
            let start = position + 10
            guard MediaBounds.contains(start, frameSize, end: body.count) else { throw TagWriteError.malformed("a frame runs past the tag") }
            if frameSize > 0 { frames.append(Frame(id: id, flags: frameFlags, payload: Array(body[start..<start + frameSize]))) }
            position = start + frameSize
        }
        return ParsedTag(major: major, revision: head[4], frames: frames, length: total)
    }

    /// The text a frame carries, read the way the indexer reads it; nil for compressed or encrypted frames.
    static func text(of frame: Frame, major: UInt8) -> String? {
        let compressed = major == 4 ? frame.flags & 0x0008 != 0 : frame.flags & 0x0080 != 0
        let encrypted = major == 4 ? frame.flags & 0x0004 != 0 : frame.flags & 0x0040 != 0
        guard !compressed, !encrypted else { return nil }
        var payload = frame.payload
        if major == 4, frame.flags & 0x0002 != 0 { payload = ID3Tags.unsynchronised(payload) }
        let groupLength = (major == 3 ? frame.flags & 0x0020 : frame.flags & 0x0040) != 0 ? 1 : 0
        let indicatorLength = major == 4 && frame.flags & 0x0001 != 0 ? 4 : 0
        let prefix = groupLength + indicatorLength
        guard MediaBounds.contains(0, prefix, end: payload.count) else { return nil }
        return ID3Tags.textFrame(Array(payload.dropFirst(prefix)))
    }

    // MARK: Editing

    /// Replaces every frame with this id by one plain text frame, in the first one's place. A new
    /// frame goes before the pictures, where players expect text.
    static func replace(_ id: String, with text: String, in tag: inout ParsedTag) {
        let frame = Frame(id: id, flags: 0, payload: textPayload(text, major: tag.major))
        let index = tag.frames.firstIndex { $0.id == id } ?? tag.frames.firstIndex { $0.id == "APIC" } ?? tag.frames.count
        tag.frames.removeAll { $0.id == id }
        tag.frames.insert(frame, at: min(index, tag.frames.count))
    }

    /// UTF-8 in v2.4; in v2.3 Latin-1 when the text fits it, otherwise UTF-16 with a byte order mark.
    static func textPayload(_ text: String, major: UInt8) -> [UInt8] {
        if major == 4 { return [3] + Array(text.utf8) }
        if let latin = text.data(using: .isoLatin1) { return [0] + [UInt8](latin) }
        return [1, 0xFF, 0xFE] + [UInt8](text.data(using: .utf16LittleEndian) ?? Data())
    }

    // MARK: Serialising

    static func serialise(_ tag: ParsedTag) throws -> [UInt8] {
        var body: [UInt8] = []
        for frame in tag.frames {
            let size = frame.payload.count
            guard frame.id.utf8.count == 4, size > 0, size < (tag.major == 4 ? 1 << 28 : Int(UInt32.max)) else {
                throw TagWriteError.tooLarge
            }
            body += Array(frame.id.utf8)
            body += tag.major == 4 ? TagWriter.syncsafeBytes(size) : TagWriter.bigEndian32(size)
            body += [UInt8(frame.flags >> 8), UInt8(frame.flags & 0xFF)]
            body += frame.payload
        }
        // The previous tag's bytes are reused when the frames fit, so the audio stays where it was;
        // a dropped v2.4 footer simply becomes padding. Otherwise the tag grows with some spare room.
        let previousBody = tag.length > 0 ? tag.length - 10 : 0
        let bodyLength = body.count <= previousBody ? previousBody : body.count + growthPadding
        guard bodyLength < 1 << 28, Int64(bodyLength + 10) <= ID3Tags.maximumTag else { throw TagWriteError.tooLarge }
        var result = Array("ID3".utf8) + [tag.major, tag.revision, 0] + TagWriter.syncsafeBytes(bodyLength)
        result += body
        result += [UInt8](repeating: 0, count: bodyLength - body.count)
        return result
    }

    /// The trailing ID3v1 tag with the edited fields, or nil when the file has none.
    static func patchedID3v1(edits: TagEdits, fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> [UInt8]? {
        guard fileSize >= 128 else { return nil }
        var tail = [UInt8](try read(fileSize - 128..<fileSize))
        guard tail.count == 128, tail[0] == 0x54, tail[1] == 0x41, tail[2] == 0x47 else { return nil }
        if let album = edits.album {
            let field = Array([UInt8](album.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()).prefix(30))
            tail.replaceSubrange(63..<93, with: field + [UInt8](repeating: 0, count: 30 - field.count))
        }
        if let genre = edits.genre {
            // The single genre byte indexes the ID3v1 list; anything else is 255, "none".
            let index = MediaProbe.id3Genres.firstIndex { $0.caseInsensitiveCompare(genre) == .orderedSame }
            tail[127] = index.map { UInt8($0) } ?? 255
        }
        return tail
    }
}
