import Foundation

/// Rewrites the Vorbis comment block at the start of a FLAC file. Every other metadata block
/// (stream info, seek table, pictures, cue sheets, application data) is copied byte for byte and
/// the audio frames never move: padding absorbs the change in size whenever it can, and FLAC has
/// no absolute offsets, so growing the header when it cannot is safe too.
nonisolated enum FLACTagWriter {
    /// Padding written when the header has to grow, so the next edit fits without growing it again.
    static let growthPadding = 4096
    private static let streamInfo = 0
    private static let padding = 1
    private static let vorbisComment = 4

    struct Block: Equatable {
        var type: Int
        var data: [UInt8]
    }

    static func plan(edits: TagEdits, fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> TagRewrite? {
        let (blocks, audioStart) = try parseBlocks(fileSize: fileSize, read: read)
        guard blocks.first?.type == streamInfo else { throw TagWriteError.malformed("the stream info block is not first") }
        let comments = blocks.indices.filter { blocks[$0].type == vorbisComment }
        guard comments.count <= 1 else { throw TagWriteError.malformed("more than one Vorbis comment block") }
        var rebuilt: [Block] = []
        var changed = false
        if let index = comments.first {
            guard let (data, didChange) = try rebuildComments(blocks[index].data, edits: edits) else {
                throw TagWriteError.malformed("Vorbis comment block")
            }
            changed = didChange
            rebuilt = blocks
            rebuilt[index].data = data
        } else {
            // No comments yet: a new block right after the stream info, where encoders put it.
            rebuilt = blocks
            rebuilt.insert(Block(type: vorbisComment, data: newComments(edits: edits)), at: 1)
            changed = true
        }
        guard changed else { return nil }
        // One padding block at the end keeps the audio where it is whenever the new blocks fit.
        let kept = rebuilt.filter { $0.type != padding }
        let sizeWithoutPadding = kept.reduce(0) { $0 + 4 + $1.data.count }
        let previousLength = audioStart - 4
        var blocksToWrite = kept
        if sizeWithoutPadding + 4 <= previousLength {
            blocksToWrite.append(Block(type: padding, data: [UInt8](repeating: 0, count: previousLength - sizeWithoutPadding - 4)))
        } else if sizeWithoutPadding != previousLength {
            blocksToWrite.append(Block(type: padding, data: [UInt8](repeating: 0, count: growthPadding)))
        }
        var header = Array("fLaC".utf8)
        for (index, block) in blocksToWrite.enumerated() {
            guard block.data.count < 1 << 24 else { throw TagWriteError.tooLarge }
            let isLast = index == blocksToWrite.count - 1
            header.append(UInt8(block.type) | (isLast ? 0x80 : 0))
            header += [UInt8((block.data.count >> 16) & 0xFF), UInt8((block.data.count >> 8) & 0xFF), UInt8(block.data.count & 0xFF)]
            header += block.data
        }
        guard Int64(header.count) <= FLACHeader.maximumRead else { throw TagWriteError.tooLarge }
        return TagRewrite(segments: [.bytes(header), .copy(Int64(audioStart)..<fileSize)])
    }

    // MARK: Blocks

    /// Every metadata block and the offset of the first audio frame. Reads a longer prefix when a block
    /// runs past the current one, up to the same limit the reader applies.
    static func parseBlocks(fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> ([Block], Int) {
        var wanted = min(fileSize, FLACHeader.initialRead)
        while true {
            let bytes = [UInt8](try read(0..<wanted))
            guard bytes.count >= 8, TagWriter.isFLAC(bytes) else { throw TagWriteError.malformed("not a FLAC stream") }
            var blocks: [Block] = []
            var offset = 4
            var needed: Int?
            while true {
                guard MediaBounds.contains(offset, 4, end: bytes.count) else { needed = offset + 4; break }
                let header = bytes[offset]
                let type = Int(header & 0x7F)
                guard type != 127 else { throw TagWriteError.malformed("invalid block type") }
                let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                let start = offset + 4
                guard MediaBounds.contains(start, length, end: bytes.count) else { needed = start + length; break }
                blocks.append(Block(type: type, data: Array(bytes[start..<start + length])))
                offset = start + length
                if header & 0x80 != 0 { return (blocks, offset) }
            }
            guard let needed, Int64(needed) <= min(fileSize, FLACHeader.maximumRead), Int64(needed) > wanted else {
                throw TagWriteError.malformed("the metadata blocks run past the readable prefix")
            }
            wanted = Int64(needed)
        }
    }

    // MARK: Comments

    /// The comment block with the edited fields, and whether anything changed; nil when it cannot be parsed.
    static func rebuildComments(_ block: [UInt8], edits: TagEdits) throws -> ([UInt8], Bool)? {
        var offset = 0
        func readUInt32() -> Int? {
            guard MediaBounds.contains(offset, 4, end: block.count) else { return nil }
            let value = Int(block[offset]) | Int(block[offset + 1]) << 8 | Int(block[offset + 2]) << 16 | Int(block[offset + 3]) << 24
            offset += 4
            return value
        }
        guard let vendorLength = readUInt32(), MediaBounds.contains(offset, vendorLength, end: block.count) else { return nil }
        let vendor = Array(block[offset..<offset + vendorLength])
        offset += vendorLength
        guard let count = readUInt32() else { return nil }
        var comments: [[UInt8]] = []
        for _ in 0..<count {
            guard let length = readUInt32(), MediaBounds.contains(offset, length, end: block.count) else { return nil }
            comments.append(Array(block[offset..<offset + length]))
            offset += length
        }
        var changed = false
        if let genre = edits.genre {
            changed = replace(key: "GENRE", with: genre, in: &comments) || changed
        }
        if let album = edits.albumValue(replacing: firstValue(forKey: "ALBUM", in: comments)) {
            changed = replace(key: "ALBUM", with: album, in: &comments) || changed
        }
        guard changed else { return (block, false) }
        return (serialise(vendor: vendor, comments: comments), true)
    }

    private static func key(of comment: [UInt8]) -> String? {
        guard let equals = comment.firstIndex(of: 0x3D) else { return nil }
        return String(decoding: comment[..<equals], as: UTF8.self).uppercased()
    }

    /// The first value stored under `key`, which is the one the reader shows.
    private static func firstValue(forKey key: String, in comments: [[UInt8]]) -> String? {
        for comment in comments where self.key(of: comment) == key {
            guard let equals = comment.firstIndex(of: 0x3D) else { continue }
            let value = String(decoding: comment[(equals + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// One comment for the key, in the place of the first existing one; returns whether the block changed.
    private static func replace(key: String, with value: String, in comments: inout [[UInt8]]) -> Bool {
        let matching = comments.indices.filter { self.key(of: comments[$0]) == key }
        if matching.count == 1, firstValue(forKey: key, in: comments) == value { return false }
        let entry = Array((key + "=" + value).utf8)
        let position = matching.first ?? comments.count
        comments = comments.enumerated().filter { !matching.contains($0.offset) }.map(\.element)
        comments.insert(entry, at: min(position, comments.count))
        return true
    }

    private static func serialise(vendor: [UInt8], comments: [[UInt8]]) -> [UInt8] {
        var result = TagWriter.littleEndian32(vendor.count) + vendor + TagWriter.littleEndian32(comments.count)
        for comment in comments {
            result += TagWriter.littleEndian32(comment.count) + comment
        }
        return result
    }

    private static func newComments(edits: TagEdits) -> [UInt8] {
        var comments: [[UInt8]] = []
        if let album = edits.album { comments.append(Array("ALBUM=\(album)".utf8)) }
        if let genre = edits.genre { comments.append(Array("GENRE=\(genre)".utf8)) }
        return serialise(vendor: Array("Skyr".utf8), comments: comments)
    }
}
