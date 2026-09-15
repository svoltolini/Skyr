import Foundation

/// Tag values to write into a song's file. A nil field is left exactly as the file has it.
public nonisolated struct TagEdits: Hashable, Sendable {
    public var album: String?
    public var genre: String?

    public init(album: String? = nil, genre: String? = nil) {
        self.album = album.nonEmpty
        self.genre = genre.nonEmpty
    }

    public var isEmpty: Bool { album == nil && genre == nil }

    /// The album title to store, given what the file holds now. A "(Disc 2)" marker that the file
    /// keeps in its album tag is carried over, so renaming a boxed set never loses its disc numbers.
    public func albumValue(replacing existing: String?) -> String? {
        guard let album else { return nil }
        guard let existing = existing.nonEmpty, PathParser.splitDisc(album).disc == nil else { return album }
        let split = PathParser.splitDisc(existing)
        guard split.disc != nil, let markerStart = existing.range(of: split.title)?.upperBound else { return album }
        let marker = existing[markerStart...]
        return album + marker
    }
}

/// Why a file's tags could not be rewritten. Every case leaves the file untouched.
public nonisolated enum TagWriteError: LocalizedError, Sendable, Equatable {
    /// The format has no tag scheme Skyr writes; the argument is the file extension.
    case unsupportedFormat(String)
    /// The file's contents do not match its name, e.g. a WAV inside a .mp3.
    case mismatchedContents(String)
    /// The ID3v2 version is one Skyr does not rewrite (v2.2).
    case unsupportedTagVersion(Int)
    /// A fragmented movie or other layout whose offsets cannot be maintained safely.
    case unsupportedLayout(String)
    /// The existing tags could not be parsed, so they cannot be preserved.
    case malformed(String)
    /// The rewritten tag would exceed the size Skyr is willing to read back.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "Skyr can't edit the tags of \(ext.isEmpty ? "this kind of" : ext.uppercased()) files yet."
        case .mismatchedContents(let detail):
            "The file's contents don't match its name (\(detail)), so it was left unchanged."
        case .unsupportedTagVersion(let version):
            "This song has an ID3v2.\(version) tag, which Skyr doesn't rewrite. Save it with a newer tag version first."
        case .unsupportedLayout(let detail):
            "This file's layout (\(detail)) can't be rewritten safely, so it was left unchanged."
        case .malformed(let detail):
            "The file's tags couldn't be read completely (\(detail)), so it was left unchanged."
        case .tooLarge:
            "The rewritten tag would be too large, so the file was left unchanged."
        }
    }
}

/// One piece of a rewritten file: new bytes, or a stretch of the original copied as it is.
public nonisolated enum FileSegment: Hashable, Sendable {
    case bytes([UInt8])
    case copy(Range<Int64>)

    public var length: Int64 {
        switch self {
        case .bytes(let bytes): Int64(bytes.count)
        case .copy(let range): range.upperBound - range.lowerBound
        }
    }
}

/// How to produce the rewritten file from the original.
public nonisolated struct TagRewrite: Hashable, Sendable {
    public let segments: [FileSegment]

    public init(segments: [FileSegment]) {
        self.segments = segments
    }

    public var newSize: Int64 { segments.reduce(0) { $0 + $1.length } }

    /// Runs the plan against the original file, chunking the copied stretches so a large song never sits in memory.
    public func write(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for segment in segments {
            switch segment {
            case .bytes(let bytes):
                try output.write(contentsOf: Data(bytes))
            case .copy(let range):
                try input.seek(toOffset: UInt64(range.lowerBound))
                var remaining = range.upperBound - range.lowerBound
                while remaining > 0 {
                    let chunk = Int(min(remaining, 1 << 20))
                    guard let data = try input.read(upToCount: chunk), !data.isEmpty else {
                        throw TagWriteError.malformed("the file ended early")
                    }
                    try output.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
            }
        }
        try output.synchronize()
    }
}

/// The tags Skyr has just read back from a rewritten file, to confirm the write landed and nothing else moved.
public nonisolated struct WrittenTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var trackNumber: Int?
}

/// Plans the rewrite of a song's tags: the format-specific writers change only the requested
/// fields and copy every other frame, atom, block and the audio itself byte for byte. Sizes are
/// checked against the same limits the readers apply, so a rewritten file is always one Skyr can read.
public nonisolated enum TagWriter {
    /// Extensions Skyr rewrites. Everything else fails with `unsupportedFormat` before any transfer.
    public static let supportedExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "alac", "flac"]

    /// The largest file worth downloading, rewriting and uploading for a tag change.
    public static let maximumFileSize: Int64 = 2 * 1024 * 1024 * 1024

    public static func supports(fileName: String) -> Bool {
        supportedExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// The plan for `edits`, or nil when the file already holds those values. `read` returns the
    /// requested byte range of the original file, short when the file ends first.
    public static func plan(edits: TagEdits, fileName: String, fileSize: Int64, read: (Range<Int64>) throws -> Data) throws -> TagRewrite? {
        guard !edits.isEmpty else { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw TagWriteError.unsupportedFormat(ext) }
        guard fileSize > 0, fileSize <= maximumFileSize else { throw TagWriteError.tooLarge }
        let head = [UInt8](try read(0..<min(fileSize, 16)))
        switch ext {
        case "mp3":
            guard !isFLAC(head), !isMP4(head), !hasSignature(head, "RIFF"), !hasSignature(head, "OggS") else {
                throw TagWriteError.mismatchedContents("not MPEG audio")
            }
            return try ID3TagWriter.plan(edits: edits, fileSize: fileSize, read: read)
        case "m4a", "mp4", "aac", "alac":
            guard isMP4(head) else { throw TagWriteError.mismatchedContents("not an MPEG-4 container") }
            return try MP4TagWriter.plan(edits: edits, fileSize: fileSize, read: read)
        case "flac":
            guard isFLAC(head) else { throw TagWriteError.mismatchedContents("not a FLAC stream") }
            return try FLACTagWriter.plan(edits: edits, fileSize: fileSize, read: read)
        default:
            throw TagWriteError.unsupportedFormat(ext)
        }
    }

    /// Plans and writes in one go for a file on disk. Returns false when nothing needed changing.
    @discardableResult
    public static func rewrite(edits: TagEdits, fileName: String, source: URL, destination: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let plan = try plan(edits: edits, fileName: fileName, fileSize: size) { range in
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        }
        guard let plan else { return false }
        try plan.write(from: source, to: destination)
        return true
    }

    /// Reads a rewritten file's tags back with the same readers the indexer uses.
    public static func readBack(fileName: String, at url: URL) async throws -> WrittenTags? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let read: (Range<Int64>) async throws -> Data = { range in
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp3":
            guard let media = try await ID3Tags.read(fileSize: size, read: read) else { return nil }
            return WrittenTags(title: media.title, artist: media.artist, album: media.album, genre: media.genre, trackNumber: media.trackNumber)
        case "m4a", "mp4", "aac", "alac":
            guard let media = try await MP4Tags.read(read: read) else { return nil }
            return WrittenTags(title: media.title, artist: media.artist, album: media.album, genre: media.genre, trackNumber: media.trackNumber)
        case "flac":
            var prefix = try await read(0..<min(size, FLACHeader.initialRead))
            guard var info = FLACHeader.parse(prefix) else { return nil }
            if let needed = info.neededPrefix, Int64(needed) > Int64(prefix.count), Int64(needed) <= FLACHeader.maximumRead {
                prefix = try await read(0..<Int64(needed))
                info = FLACHeader.parse(prefix) ?? info
            }
            return WrittenTags(title: info.tag("TITLE"), artist: info.tag("ARTIST"), album: info.tag("ALBUM"), genre: info.tag("GENRE"), trackNumber: info.number("TRACKNUMBER"))
        default:
            return nil
        }
    }

    static func isFLAC(_ head: [UInt8]) -> Bool { hasSignature(head, "fLaC") }

    static func hasSignature(_ head: [UInt8], _ signature: String) -> Bool {
        let bytes = Array(signature.utf8)
        return head.count >= bytes.count && Array(head[0..<bytes.count]) == bytes
    }

    static func isMP4(_ head: [UInt8]) -> Bool {
        head.count >= 8 && MP4Tags.fourCC(head, 4) == "ftyp"
    }

    // MARK: Byte helpers shared by the writers

    static func bigEndian32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    static func bigEndian64(_ value: Int64) -> [UInt8] {
        let v = UInt64(bitPattern: value)
        return (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64($0))) }
    }

    static func littleEndian32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(v >> 24)]
    }

    static func syncsafeBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }
}
