import Foundation

/// Rewrites the iTunes-style tags in an MPEG-4 audio file's `moov` atom. Only the edited `ilst`
/// items change; every other atom is copied as it is. Growth is first absorbed by a `free` atom
/// next to `moov`, so the audio stays put; when that is impossible the chunk offset tables are
/// shifted along with the data they point at, the way iTunes and other taggers do.
nonisolated enum MP4TagWriter {
    private static let albumItem = "\u{A9}alb"
    private static let genreItem = "\u{A9}gen"
    private static let predefinedGenreItem = "gnre"
    /// Spare room left after a `moov` that had to grow, so the next edit does not move the audio again.
    static let growthPadding: Int64 = 1024

    struct TopLevelAtom: Equatable {
        let type: String
        let start: Int64
        let headerLength: Int64
        let end: Int64
    }

    static func plan(edits: TagEdits, fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> TagRewrite? {
        let atoms = try topLevelAtoms(fileSize: fileSize, read: read)
        guard atoms.first?.type == "ftyp" else { throw TagWriteError.malformed("the file does not start with ftyp") }
        guard !atoms.contains(where: { $0.type == "moof" || $0.type == "sidx" }) else {
            throw TagWriteError.unsupportedLayout("fragmented MPEG-4")
        }
        let movies = atoms.filter { $0.type == "moov" }
        guard movies.count == 1, let moov = movies.first else { throw TagWriteError.malformed("\(movies.count) moov atoms") }
        let moovLength = moov.end - moov.start
        guard moovLength <= MP4Tags.maximumMoov, let count = Int(exactly: moovLength) else { throw TagWriteError.tooLarge }
        let moovBytes = [UInt8](try read(moov.start..<moov.end))
        guard moovBytes.count == count else { throw TagWriteError.malformed("moov could not be read in full") }
        guard let rebuilt = try rebuildMoov(moovBytes, headerLength: Int(moov.headerLength), edits: edits) else { return nil }
        guard Int64(rebuilt.count) <= MP4Tags.maximumMoov else { throw TagWriteError.tooLarge }

        // The bytes being replaced: moov and any free space directly after it.
        var regionEnd = moov.end
        if let trailing = atoms.first(where: { $0.start == moov.end && isFree($0.type) }) { regionEnd = trailing.end }
        let regionLength = regionEnd - moov.start
        let dataFollows = atoms.contains { $0.start >= regionEnd && !isFree($0.type) }
        var replacement = rebuilt
        let newLength = Int64(rebuilt.count)
        if newLength == regionLength {
            // Same size: nothing after it moves.
        } else if newLength + 8 <= regionLength {
            replacement += freeAtom(totalSize: regionLength - newLength)
        } else if !dataFollows {
            replacement += freeAtom(totalSize: growthPadding)
        } else {
            replacement += freeAtom(totalSize: growthPadding)
            let delta = Int64(replacement.count) - regionLength
            replacement = try shiftChunkOffsets(in: replacement, by: delta, atOrAfter: regionEnd)
        }
        return TagRewrite(segments: [.copy(0..<moov.start), .bytes(replacement), .copy(regionEnd..<fileSize)])
    }

    // MARK: Top level

    static func topLevelAtoms(fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> [TopLevelAtom] {
        var atoms: [TopLevelAtom] = []
        var position: Int64 = 0
        while position < fileSize {
            guard atoms.count < 256 else { throw TagWriteError.malformed("too many top-level atoms") }
            let header = [UInt8](try read(position..<min(fileSize, position + 16)))
            guard header.count >= 8 else { throw TagWriteError.malformed("truncated atom header") }
            var size = Int64(MP4Tags.u32(header, 0))
            var headerLength: Int64 = 8
            let type = MP4Tags.fourCC(header, 4)
            if size == 1 {
                guard header.count >= 16, let extended = Int64(exactly: MP4Tags.u64(header, 8)) else { throw TagWriteError.malformed("atom size") }
                size = extended
                headerLength = 16
            } else if size == 0 {
                size = fileSize - position
            }
            guard size >= headerLength, let range = MediaBounds.range(position, length: size), range.upperBound <= fileSize else {
                throw TagWriteError.malformed("atom size")
            }
            atoms.append(TopLevelAtom(type: type, start: position, headerLength: headerLength, end: range.upperBound))
            position = range.upperBound
        }
        return atoms
    }

    private static func isFree(_ type: String) -> Bool { type == "free" || type == "skip" }

    // MARK: moov

    /// The rebuilt `moov` atom, or nil when its tags already hold the edited values.
    static func rebuildMoov(_ b: [UInt8], headerLength: Int, edits: TagEdits) throws -> [UInt8]? {
        let children = MP4Tags.boxes(b, headerLength, b.count)
        guard !children.isEmpty, children.last?.2 == b.count else { throw TagWriteError.malformed("moov") }
        guard !children.contains(where: { $0.0 == "mvex" }) else { throw TagWriteError.unsupportedLayout("fragmented MPEG-4") }
        // Tags live in udta/meta/ilst, or in a meta atom directly under moov; a missing path is created.
        var path = ["udta", "meta", "ilst"]
        if let udta = children.first(where: { $0.0 == "udta" }) {
            let userDataHasMeta = MP4Tags.boxes(b, udta.1, udta.2).contains { $0.0 == "meta" }
            if !userDataHasMeta, children.contains(where: { $0.0 == "meta" }) { path = ["meta", "ilst"] }
        } else if children.contains(where: { $0.0 == "meta" }) {
            path = ["meta", "ilst"]
        }
        let (payload, changed) = try rebuildContainer(b, headerLength, b.count, path: path[...], edits: edits)
        guard changed else { return nil }
        return try atom("moov", payload)
    }

    /// Rebuilds one container along `path`, copying every child that is not on the path untouched.
    private static func rebuildContainer(_ b: [UInt8], _ start: Int, _ end: Int, path: ArraySlice<String>, edits: TagEdits) throws -> (payload: [UInt8], changed: Bool) {
        guard let target = path.first else { return try rebuildItemList(b, start, end, edits: edits) }
        let children = MP4Tags.boxes(b, start, end)
        guard (children.last?.2 ?? start) == end else { throw TagWriteError.malformed("\(target) container has trailing bytes") }
        var payload: [UInt8] = []
        var position = start
        var handled = false
        var changed = false
        for child in children {
            let headerStart = position
            position = child.2
            guard child.0 == target, !handled else {
                payload += try normalisedCopy(b, headerStart: headerStart, child)
                continue
            }
            handled = true
            // meta is a full box: four bytes of version and flags before its children.
            let isFull = target == "meta"
            guard !isFull || MediaBounds.contains(child.1, 4, end: child.2) else { throw TagWriteError.malformed("meta") }
            let inner = try rebuildContainer(b, child.1 + (isFull ? 4 : 0), child.2, path: path.dropFirst(), edits: edits)
            guard inner.changed else {
                payload += try normalisedCopy(b, headerStart: headerStart, child)
                continue
            }
            changed = true
            let prefix = isFull ? Array(b[child.1..<child.1 + 4]) : []
            payload += try atom(target, prefix + inner.payload)
        }
        if !handled {
            payload += try newSubtree(path: path, edits: edits)
            changed = true
        }
        return (payload, changed)
    }

    /// The edited `ilst` payload. Items other than the edited ones are copied byte for byte.
    private static func rebuildItemList(_ b: [UInt8], _ start: Int, _ end: Int, edits: TagEdits) throws -> (payload: [UInt8], changed: Bool) {
        let items = MP4Tags.boxes(b, start, end)
        guard (items.last?.2 ?? start) == end else { throw TagWriteError.malformed("ilst has trailing bytes") }
        var currentGenre = items.first { $0.0 == genreItem }.flatMap { text(of: $0, in: b) }
        if currentGenre == nil, let predefined = items.first(where: { $0.0 == predefinedGenreItem }),
           let data = MP4Tags.boxes(b, predefined.1, predefined.2).first(where: { $0.0 == "data" }),
           MediaBounds.contains(data.1, 10, end: data.2) {
            let index = Int(b[data.2 - 2]) << 8 | Int(b[data.2 - 1])
            if index >= 1, index <= MediaProbe.id3Genres.count { currentGenre = MediaProbe.id3Genres[index - 1] }
        }
        let currentAlbum = items.first { $0.0 == albumItem }.flatMap { text(of: $0, in: b) }
        var replacements: [String: String] = [:]
        var removed: Set<String> = []
        if let genre = edits.genre, genre != currentGenre {
            replacements[genreItem] = genre
            removed.formUnion([genreItem, predefinedGenreItem])
        }
        if let album = edits.albumValue(replacing: currentAlbum), album != currentAlbum {
            replacements[albumItem] = album
            removed.insert(albumItem)
        }
        guard !replacements.isEmpty else { return (Array(b[start..<end]), false) }
        var payload: [UInt8] = []
        var position = start
        var inserted: Set<String> = []
        for item in items {
            let headerStart = position
            position = item.2
            guard removed.contains(item.0) else {
                payload += try normalisedCopy(b, headerStart: headerStart, item)
                continue
            }
            // The new value takes the first old item's place; further copies of it are dropped.
            let key = item.0 == predefinedGenreItem ? genreItem : item.0
            if let value = replacements[key], !inserted.contains(key) {
                payload += try textItem(key, value)
                inserted.insert(key)
            }
        }
        for (key, value) in replacements.sorted(by: { $0.key < $1.key }) where !inserted.contains(key) {
            payload += try textItem(key, value)
        }
        return (payload, true)
    }

    /// The text of an item's `data` atom, decoded the way the indexer decodes it.
    private static func text(of item: (String, Int, Int), in b: [UInt8]) -> String? {
        guard let data = MP4Tags.boxes(b, item.1, item.2).first(where: { $0.0 == "data" }),
              MediaBounds.contains(data.1, 8, end: data.2) else { return nil }
        let kind = Int(MP4Tags.u32(b, data.1)) & 0x00FF_FFFF
        let value = Array(b[(data.1 + 8)..<data.2])
        let string = kind == 1 ? String(bytes: value, encoding: .utf8) : String(bytes: value, encoding: .isoLatin1)
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A child copied as it is, unless its header needs normalising: a size of zero means "to the
    /// end of the parent", which would swallow anything appended after it.
    private static func normalisedCopy(_ b: [UInt8], headerStart: Int, _ child: (String, Int, Int)) throws -> [UInt8] {
        let declared = Int(MP4Tags.u32(b, headerStart))
        if child.1 - headerStart == 8, declared == child.2 - headerStart {
            return Array(b[headerStart..<child.2])
        }
        return try atom(child.0, Array(b[child.1..<child.2]))
    }

    private static func newSubtree(path: ArraySlice<String>, edits: TagEdits) throws -> [UInt8] {
        guard let first = path.first else { return [] }
        switch first {
        case "ilst":
            var items: [UInt8] = []
            if let album = edits.album { items += try textItem(albumItem, album) }
            if let genre = edits.genre { items += try textItem(genreItem, genre) }
            return try atom("ilst", items)
        case "meta":
            return try atom("meta", [0, 0, 0, 0] + handlerAtom() + newSubtree(path: path.dropFirst(), edits: edits))
        default:
            return try atom(first, try newSubtree(path: path.dropFirst(), edits: edits))
        }
    }

    // MARK: Chunk offsets

    /// Adds `delta` to every chunk offset at or after `threshold`, in every track's `stco` or `co64` table.
    static func shiftChunkOffsets(in moov: [UInt8], by delta: Int64, atOrAfter threshold: Int64) throws -> [UInt8] {
        var bytes = moov
        for trak in MP4Tags.boxes(bytes, 8, bytes.count) where trak.0 == "trak" {
            guard let mdia = MP4Tags.boxes(bytes, trak.1, trak.2).first(where: { $0.0 == "mdia" }),
                  let minf = MP4Tags.boxes(bytes, mdia.1, mdia.2).first(where: { $0.0 == "minf" }),
                  let stbl = MP4Tags.boxes(bytes, minf.1, minf.2).first(where: { $0.0 == "stbl" }) else { continue }
            for table in MP4Tags.boxes(bytes, stbl.1, stbl.2) where table.0 == "stco" || table.0 == "co64" {
                guard MediaBounds.contains(table.1, 8, end: table.2) else { throw TagWriteError.malformed("chunk offset table") }
                let count = Int(MP4Tags.u32(bytes, table.1 + 4))
                let width = table.0 == "stco" ? 4 : 8
                guard MediaBounds.contains(table.1 + 8, count * width, end: table.2) else { throw TagWriteError.malformed("chunk offset table") }
                for index in 0..<count {
                    let at = table.1 + 8 + index * width
                    if width == 4 {
                        let offset = Int64(MP4Tags.u32(bytes, at))
                        guard offset >= threshold else { continue }
                        let shifted = offset + delta
                        guard shifted >= 0, shifted <= Int64(UInt32.max) else { throw TagWriteError.tooLarge }
                        bytes.replaceSubrange(at..<at + 4, with: TagWriter.bigEndian32(Int(shifted)))
                    } else {
                        guard let offset = Int64(exactly: MP4Tags.u64(bytes, at)) else { throw TagWriteError.malformed("chunk offset") }
                        guard offset >= threshold else { continue }
                        let shifted = offset + delta
                        guard shifted >= 0 else { throw TagWriteError.malformed("chunk offset") }
                        bytes.replaceSubrange(at..<at + 8, with: TagWriter.bigEndian64(shifted))
                    }
                }
            }
        }
        return bytes
    }

    // MARK: Atoms

    static func atom(_ type: String, _ payload: [UInt8]) throws -> [UInt8] {
        guard let name = type.data(using: .isoLatin1), name.count == 4, payload.count + 8 < Int(UInt32.max) else {
            throw TagWriteError.tooLarge
        }
        return TagWriter.bigEndian32(payload.count + 8) + [UInt8](name) + payload
    }

    static func textItem(_ type: String, _ text: String) throws -> [UInt8] {
        // A data atom of type 1: UTF-8 text with an empty locale.
        try atom(type, try atom("data", [0, 0, 0, 1] + [0, 0, 0, 0] + Array(text.utf8)))
    }

    /// The handler iTunes writes ahead of its item list.
    private static func handlerAtom() throws -> [UInt8] {
        try atom("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + Array("mdir".utf8) + Array("appl".utf8) + [UInt8](repeating: 0, count: 9))
    }

    static func freeAtom(totalSize: Int64) -> [UInt8] {
        if totalSize < Int64(UInt32.max) {
            return TagWriter.bigEndian32(Int(totalSize)) + Array("free".utf8) + [UInt8](repeating: 0, count: Int(totalSize) - 8)
        }
        return TagWriter.bigEndian32(1) + Array("free".utf8) + TagWriter.bigEndian64(totalSize) + [UInt8](repeating: 0, count: Int(totalSize) - 16)
    }
}
