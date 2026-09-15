import Foundation
import Testing
@testable import SkyrCore

// MARK: - Shared fixture helpers

private nonisolated func be32(_ value: Int) -> [UInt8] {
    let v = UInt32(truncatingIfNeeded: value)
    return [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

private nonisolated func le32(_ value: Int) -> [UInt8] {
    let v = UInt32(truncatingIfNeeded: value)
    return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(v >> 24)]
}

private nonisolated func syncsafe(_ value: Int) -> [UInt8] {
    [UInt8((value >> 21) & 127), UInt8((value >> 14) & 127), UInt8((value >> 7) & 127), UInt8(value & 127)]
}

private nonisolated func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

private nonisolated let pictureBytes = [UInt8](Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!)

/// Applies a plan to in-memory bytes the way the file assembler does on disk.
private nonisolated func assemble(_ plan: TagRewrite, from original: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    for segment in plan.segments {
        switch segment {
        case .bytes(let bytes): result += bytes
        case .copy(let range): result += original[Int(range.lowerBound)..<Int(range.upperBound)]
        }
    }
    return result
}

private nonisolated func plan(_ edits: TagEdits, _ name: String, _ bytes: [UInt8]) throws -> TagRewrite? {
    try TagWriter.plan(edits: edits, fileName: name, fileSize: Int64(bytes.count)) { range in
        let start = min(bytes.count, Int(range.lowerBound))
        let end = min(bytes.count, Int(range.upperBound))
        return Data(bytes[start..<end])
    }
}

private nonisolated func rewritten(_ edits: TagEdits, _ name: String, _ bytes: [UInt8]) throws -> [UInt8] {
    let plan = try #require(try plan(edits, name, bytes))
    return assemble(plan, from: bytes)
}

private nonisolated func readID3(_ bytes: [UInt8]) async throws -> ProbedMedia? {
    try await ID3Tags.read(fileSize: Int64(bytes.count)) { range in
        Data(bytes[min(bytes.count, Int(range.lowerBound))..<min(bytes.count, Int(range.upperBound))])
    }
}

private nonisolated func readMP4(_ bytes: [UInt8]) async throws -> ProbedMedia? {
    try await MP4Tags.read { range in
        Data(bytes[min(bytes.count, Int(range.lowerBound))..<min(bytes.count, Int(range.upperBound))])
    }
}

// MARK: - ID3 fixtures

/// Two MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz) with recognisable bodies.
private nonisolated let mpegAudio: [UInt8] = {
    let header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
    let first: [UInt8] = (0..<413).map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index &* 7 &+ 3) }
    let second: [UInt8] = (0..<413).map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index &* 5 &+ 1) }
    return header + first + header + second
}()

private nonisolated func id3Frame(_ id: String, _ payload: [UInt8], version: Int, flags: [UInt8] = [0, 0]) -> [UInt8] {
    Array(id.utf8) + (version == 4 ? syncsafe(payload.count) : be32(payload.count)) + flags + payload
}

private nonisolated func id3Text(_ id: String, _ text: String, version: Int) -> [UInt8] {
    let payload: [UInt8] = version == 4 ? [3] + Array(text.utf8) : [0] + [UInt8](text.data(using: .isoLatin1)!)
    return id3Frame(id, payload, version: version)
}

private nonisolated func id3Picture(version: Int) -> [UInt8] {
    id3Frame("APIC", [0] + Array("image/png".utf8) + [0, 3, 0] + pictureBytes, version: version)
}

private nonisolated func id3Tag(version: Int, frames: [UInt8], padding: Int = 0, flags: UInt8 = 0, footer: Bool = false) -> [UInt8] {
    let body = frames + zeros(padding)
    var tag = Array("ID3".utf8) + [UInt8(version), 0, flags | (footer ? 0x10 : 0)] + syncsafe(body.count) + body
    if footer { tag += Array("3DI".utf8) + [UInt8(version), 0, flags | 0x10] + syncsafe(body.count) }
    return tag
}

private nonisolated func standardFrames(version: Int, genre: String = "Rock", album: String = "Nocturne Drift") -> [UInt8] {
    var frames: [UInt8] = id3Text("TIT2", "Morning", version: version)
    frames += id3Text("TPE1", "Halden Vey", version: version)
    frames += id3Text("TALB", album, version: version)
    frames += id3Text("TCON", genre, version: version)
    frames += id3Text("TRCK", "3/12", version: version)
    frames += id3Picture(version: version)
    return frames
}

private nonisolated func id3v1(album: String = "Nocturne Drift", genre: UInt8 = 17) -> [UInt8] {
    func field(_ text: String, _ length: Int) -> [UInt8] {
        let bytes = Array([UInt8](text.data(using: .isoLatin1)!).prefix(length))
        return bytes + zeros(length - bytes.count)
    }
    var tag: [UInt8] = Array("TAG".utf8)
    tag += field("Morning", 30)
    tag += field("Halden Vey", 30)
    tag += field(album, 30)
    tag += field("2023", 4)
    tag += field("", 28)
    tag += [0, 3, genre]
    return tag
}

// MARK: - ID3

@Suite struct ID3TagWriterTests {
    @Test(arguments: [3, 4]) func genreRewriteKeepsOtherFramesAudioAndSize(version: Int) async throws {
        let file = id3Tag(version: version, frames: standardFrames(version: version), padding: 64) + mpegAudio
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.mp3", file)
        #expect(result.count == file.count)
        #expect(Array(result.suffix(mpegAudio.count)) == mpegAudio)
        #expect(result[3] == UInt8(version))
        let media = try #require(try await readID3(result))
        #expect(media.genre == "Ambient")
        #expect(media.title == "Morning")
        #expect(media.artist == "Halden Vey")
        #expect(media.album == "Nocturne Drift")
        #expect(media.trackNumber == 3)
        #expect(media.artwork == Data(pictureBytes))
        #expect(media.codec == "mp3")
    }

    @Test(arguments: [3, 4]) func tagGrowsWithPaddingWhenNewFramesDoNotFit(version: Int) async throws {
        let file = id3Tag(version: version, frames: standardFrames(version: version)) + mpegAudio
        let longGenre = String(repeating: "Progressive ", count: 20) + "Rock"
        let result = try rewritten(TagEdits(genre: longGenre), "song.mp3", file)
        #expect(result.count > file.count)
        #expect(Array(result.suffix(mpegAudio.count)) == mpegAudio)
        let declared = ID3Tags.syncsafe(result, 6)
        #expect(result.count - mpegAudio.count == 10 + declared)
        #expect(declared >= ID3TagWriter.growthPadding)
        let media = try #require(try await readID3(result))
        #expect(media.genre == longGenre)
        #expect(media.title == "Morning")
        #expect(media.artwork == Data(pictureBytes))
    }

    @Test func untaggedFileGetsAVersion23Tag() async throws {
        let result = try rewritten(TagEdits(album: "Nocturne Drift", genre: "Ambient"), "song.mp3", mpegAudio)
        #expect(Array(result[0..<3]) == Array("ID3".utf8))
        #expect(result[3] == 3)
        #expect(Array(result.suffix(mpegAudio.count)) == mpegAudio)
        let media = try #require(try await readID3(result))
        #expect(media.genre == "Ambient")
        #expect(media.album == "Nocturne Drift")
        #expect(media.codec == "mp3")
    }

    @Test func trailingID3v1TagFollowsTheEdit() async throws {
        let file = id3Tag(version: 3, frames: standardFrames(version: 3), padding: 64) + mpegAudio + id3v1()
        let result = try rewritten(TagEdits(album: "Second Light", genre: "Jazz"), "song.mp3", file)
        #expect(result.count == file.count)
        let trailer = Array(result.suffix(128))
        #expect(Array(trailer[0..<3]) == Array("TAG".utf8))
        #expect(String(bytes: trailer[63..<75], encoding: .isoLatin1) == "Second Light")
        #expect(trailer[75..<93].allSatisfy { $0 == 0 })
        #expect(trailer[127] == 8)
        #expect(Array(result[result.count - 128 - mpegAudio.count..<result.count - 128]) == mpegAudio)
        let media = try #require(try await readID3(result))
        #expect(media.album == "Second Light")
        #expect(media.genre == "Jazz")
    }

    @Test func unknownGenreNameClearsTheID3v1GenreByte() throws {
        let file = id3Tag(version: 3, frames: standardFrames(version: 3), padding: 64) + mpegAudio + id3v1(genre: 17)
        let result = try rewritten(TagEdits(genre: "Nordic Ambient"), "song.mp3", file)
        #expect(result.last == 255)
    }

    @Test func nonLatinTextIsStoredAsUTF16InVersion23AndUTF8InVersion24() async throws {
        for version in [3, 4] {
            let file = id3Tag(version: version, frames: standardFrames(version: version), padding: 64) + mpegAudio
            let result = try rewritten(TagEdits(genre: "Классика"), "song.mp3", file)
            let media = try #require(try await readID3(result))
            #expect(media.genre == "Классика")
            #expect(media.title == "Morning")
        }
    }

    @Test func valuesAlreadyInPlaceNeedNoRewrite() throws {
        let file = id3Tag(version: 3, frames: standardFrames(version: 3, genre: "(17)"), padding: 64) + mpegAudio
        #expect(try plan(TagEdits(genre: "Rock"), "song.mp3", file) == nil)
        #expect(try plan(TagEdits(album: "Nocturne Drift"), "song.mp3", file) == nil)
        #expect(try plan(TagEdits(), "song.mp3", file) == nil)
    }

    @Test func discMarkerInTheAlbumTagSurvivesARename() async throws {
        let file = id3Tag(version: 4, frames: standardFrames(version: 4, album: "Live Sessions (Disc 2)"), padding: 64) + mpegAudio
        let result = try rewritten(TagEdits(album: "Live at Halden"), "song.mp3", file)
        let media = try #require(try await readID3(result))
        #expect(media.album == "Live at Halden (Disc 2)")
    }

    @Test func version22TagsAreRefused() throws {
        let file = Array("ID3".utf8) + [2, 0, 0] + syncsafe(30) + zeros(30) + mpegAudio
        #expect(throws: TagWriteError.unsupportedTagVersion(2)) { try plan(TagEdits(genre: "Ambient"), "song.mp3", file) }
    }

    @Test func unreadableFramesLeaveTheFileAlone() throws {
        let broken = [UInt8]([0x01, 0x02, 0x03, 0x04]) + be32(4) + [0, 0] + [0, 0, 0, 0]
        let file = id3Tag(version: 3, frames: id3Text("TIT2", "Morning", version: 3) + broken) + mpegAudio
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.mp3", file) }
        let truncated = id3Frame("TIT2", zeros(1000), version: 3)
        let short = Array("ID3".utf8) + [3, 0, 0] + syncsafe(truncated.count) + Array(truncated.prefix(40)) + mpegAudio
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.mp3", short) }
    }

    @Test func oversizedTagsAreRefusedBothWays() throws {
        let declared = Array("ID3".utf8) + [4, 0, 0] + syncsafe(9 * 1024 * 1024) + zeros(100)
        #expect(throws: TagWriteError.tooLarge) { try plan(TagEdits(genre: "Ambient"), "song.mp3", declared) }
        let file = id3Tag(version: 4, frames: standardFrames(version: 4)) + mpegAudio
        let huge = String(repeating: "x", count: Int(ID3Tags.maximumTag))
        #expect(throws: TagWriteError.tooLarge) { try plan(TagEdits(genre: huge), "song.mp3", file) }
    }

    @Test func fileThatIsNotMPEGAudioIsRefused() throws {
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.mp3", zeros(600)) }
        var flacNamedMP3 = Array("fLaC".utf8) + zeros(200)
        flacNamedMP3[4] = 0x80
        #expect(throws: TagWriteError.mismatchedContents("not MPEG audio")) { try plan(TagEdits(genre: "Ambient"), "song.mp3", flacNamedMP3) }
    }

    @Test func wholeTagUnsynchronisationIsUndoneAndFramesKept() async throws {
        // A v2.3 tag whose body was unsynchronised as a whole: every 0xFF gains a 0x00 after it.
        let frames = id3Text("TIT2", "ÿ Morning", version: 3) + id3Text("TCON", "Rock", version: 3)
        var body: [UInt8] = []
        for byte in frames {
            body.append(byte)
            if byte == 0xFF { body.append(0) }
        }
        let file = Array("ID3".utf8) + [3, 0, 0x80] + syncsafe(body.count) + body + mpegAudio
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.mp3", file)
        #expect(result[5] & 0x80 == 0)
        let media = try #require(try await readID3(result))
        #expect(media.title == "ÿ Morning")
        #expect(media.genre == "Ambient")
    }

    @Test func version24FooterIsDroppedWithoutMovingTheAudio() async throws {
        let file = id3Tag(version: 4, frames: standardFrames(version: 4), padding: 16, footer: true) + mpegAudio
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.mp3", file)
        #expect(result.count == file.count)
        #expect(result[5] & 0x10 == 0)
        #expect(Array(result.suffix(mpegAudio.count)) == mpegAudio)
        let media = try #require(try await readID3(result))
        #expect(media.genre == "Ambient")
        #expect(media.artwork == Data(pictureBytes))
    }

    @Test func extendedHeaderIsDroppedAndTextKept() async throws {
        let frames = standardFrames(version: 3)
        let extended = be32(6) + [0, 0, 0, 0, 0, 0]
        let body = extended + frames + zeros(32)
        let file = Array("ID3".utf8) + [3, 0, 0x40] + syncsafe(body.count) + body + mpegAudio
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.mp3", file)
        #expect(result.count == file.count)
        #expect(result[5] & 0x40 == 0)
        let media = try #require(try await readID3(result))
        #expect(media.genre == "Ambient")
        #expect(media.title == "Morning")
    }
}

// MARK: - MP4 fixtures

private nonisolated func atom(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    be32(payload.count + 8) + [UInt8](type.data(using: .isoLatin1)!) + payload
}

private nonisolated func mp4Text(_ name: String, _ value: String) -> [UInt8] {
    atom(name, atom("data", be32(1) + be32(0) + Array(value.utf8)))
}

private nonisolated func mp4Items(genre: [UInt8]? = mp4Text("\u{A9}gen", "Rock"), album: String = "Nocturne Drift") -> [UInt8] {
    let track = atom("trkn", atom("data", be32(0) + be32(0) + [0, 0, 0, 3, 0, 12, 0, 0]))
    let cover = atom("covr", atom("data", be32(14) + be32(0) + pictureBytes))
    return mp4Text("\u{A9}nam", "Morning") + mp4Text("\u{A9}ART", "Halden Vey") + mp4Text("\u{A9}alb", album) + (genre ?? []) + track + cover
}

private nonisolated let mp4Chunk: [UInt8] = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) }

private struct MP4Fixture {
    var bytes: [UInt8]
    var chunkOffsets: [Int]
    var moovStart: Int
    var moovLength: Int
}

/// ftyp, moov (with a sound track whose stco points into mdat), an optional free atom, and mdat;
/// or the same with moov after mdat.
private nonisolated func mp4File(items: [UInt8]?, freeSize: Int? = nil, moovLast: Bool = false, use64BitOffsets: Bool = false, extraMoovChildren: [UInt8] = [], extraTopLevel: [UInt8] = []) -> MP4Fixture {
    var header = zeros(100)
    header.replaceSubrange(12..<16, with: be32(1000))
    header.replaceSubrange(16..<20, with: be32(90_000))
    var sample = zeros(28)
    sample.replaceSubrange(16..<20, with: [0, 2, 0, 16])
    sample.replaceSubrange(24..<28, with: be32(44_100 << 16))
    let stsd = atom("stsd", be32(0) + be32(1) + atom("mp4a", sample))
    let handler = atom("hdlr", be32(0) + be32(0) + Array("soun".utf8) + zeros(13))
    func movie(offsets: [Int]) -> [UInt8] {
        let table = use64BitOffsets
            ? atom("co64", be32(0) + be32(offsets.count) + offsets.flatMap { be32(0) + be32($0) })
            : atom("stco", be32(0) + be32(offsets.count) + offsets.flatMap { be32($0) })
        let track = atom("trak", atom("mdia", handler + atom("minf", atom("stbl", stsd + table))))
        let meta = items.map { atom("udta", atom("meta", be32(0) + atom("hdlr", be32(0) + be32(0) + Array("mdir".utf8) + Array("appl".utf8) + zeros(9)) + atom("ilst", $0))) } ?? []
        return atom("moov", atom("mvhd", header) + track + meta + extraMoovChildren)
    }
    let ftyp = atom("ftyp", Array("M4A ".utf8) + be32(0))
    let mdatPayload = zeros(40) + mp4Chunk + zeros(20) + mp4Chunk
    let free = freeSize.map { atom("free", zeros($0 - 8)) } ?? []
    if moovLast {
        let mdatStart = ftyp.count
        let offsets = [mdatStart + 8 + 40, mdatStart + 8 + 40 + mp4Chunk.count + 20]
        let moov = movie(offsets: offsets)
        let bytes = ftyp + atom("mdat", mdatPayload) + moov + free + extraTopLevel
        return MP4Fixture(bytes: bytes, chunkOffsets: offsets, moovStart: ftyp.count + 8 + mdatPayload.count, moovLength: moov.count)
    }
    let probe = movie(offsets: [0, 0])
    let mdatStart = ftyp.count + probe.count + free.count + extraTopLevel.count
    let offsets = [mdatStart + 8 + 40, mdatStart + 8 + 40 + mp4Chunk.count + 20]
    let moov = movie(offsets: offsets)
    let bytes = ftyp + moov + free + extraTopLevel + atom("mdat", mdatPayload)
    return MP4Fixture(bytes: bytes, chunkOffsets: offsets, moovStart: ftyp.count, moovLength: moov.count)
}

/// The chunk offsets of the first track in a file, in file order.
private nonisolated func chunkOffsets(in bytes: [UInt8]) -> [Int] {
    let atoms = (try? MP4TagWriter.topLevelAtoms(fileSize: Int64(bytes.count)) { range in Data(bytes[Int(range.lowerBound)..<min(bytes.count, Int(range.upperBound))]) }) ?? []
    guard let moov = atoms.first(where: { $0.type == "moov" }) else { return [] }
    let start = Int(moov.start)
    let end = Int(moov.end)
    guard let trak = MP4Tags.boxes(bytes, start + Int(moov.headerLength), end).first(where: { $0.0 == "trak" }),
          let mdia = MP4Tags.boxes(bytes, trak.1, trak.2).first(where: { $0.0 == "mdia" }),
          let minf = MP4Tags.boxes(bytes, mdia.1, mdia.2).first(where: { $0.0 == "minf" }),
          let stbl = MP4Tags.boxes(bytes, minf.1, minf.2).first(where: { $0.0 == "stbl" }),
          let table = MP4Tags.boxes(bytes, stbl.1, stbl.2).first(where: { $0.0 == "stco" || $0.0 == "co64" }) else { return [] }
    let count = Int(MP4Tags.u32(bytes, table.1 + 4))
    return (0..<count).map { index in
        table.0 == "stco" ? Int(MP4Tags.u32(bytes, table.1 + 8 + index * 4)) : Int(MP4Tags.u64(bytes, table.1 + 8 + index * 8))
    }
}

private nonisolated func chunkBytes(in bytes: [UInt8], at offset: Int) -> [UInt8] {
    Array(bytes[offset..<offset + mp4Chunk.count])
}

// MARK: - MP4

@Suite struct MP4TagWriterTests {
    @Test func genreRewriteIsAbsorbedByTheFreeAtomSoNothingMoves() async throws {
        let fixture = mp4File(items: mp4Items(), freeSize: 200)
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.m4a", fixture.bytes)
        #expect(result.count == fixture.bytes.count)
        #expect(chunkOffsets(in: result) == fixture.chunkOffsets)
        for offset in fixture.chunkOffsets { #expect(chunkBytes(in: result, at: offset) == mp4Chunk) }
        let media = try #require(try await readMP4(result))
        #expect(media.genre == "Ambient")
        #expect(media.title == "Morning")
        #expect(media.artist == "Halden Vey")
        #expect(media.album == "Nocturne Drift")
        #expect(media.trackNumber == 3)
        #expect(media.artwork == Data(pictureBytes))
        #expect(media.duration == 90)
        #expect(media.codec == "aac")
    }

    @Test(arguments: [false, true]) func moovGrowthShiftsChunkOffsetsWithTheData(use64Bit: Bool) async throws {
        let fixture = mp4File(items: mp4Items(), use64BitOffsets: use64Bit)
        let longGenre = String(repeating: "Progressive ", count: 20) + "Rock"
        let result = try rewritten(TagEdits(genre: longGenre), "song.m4a", fixture.bytes)
        let delta = result.count - fixture.bytes.count
        #expect(delta > 0)
        let shifted = chunkOffsets(in: result)
        #expect(shifted == fixture.chunkOffsets.map { $0 + delta })
        for offset in shifted { #expect(chunkBytes(in: result, at: offset) == mp4Chunk) }
        let atoms = try MP4TagWriter.topLevelAtoms(fileSize: Int64(result.count)) { range in Data(result[Int(range.lowerBound)..<min(result.count, Int(range.upperBound))]) }
        #expect(atoms.map(\.type) == ["ftyp", "moov", "free", "mdat"])
        let media = try #require(try await readMP4(result))
        #expect(media.genre == longGenre)
        #expect(media.title == "Morning")
        #expect(media.artwork == Data(pictureBytes))
    }

    @Test func shorterValueLeavesFreeSpaceInsteadOfMovingTheData() async throws {
        let fixture = mp4File(items: mp4Items(genre: mp4Text("\u{A9}gen", "Progressive Symphonic Rock")))
        let result = try rewritten(TagEdits(genre: "Pop"), "song.m4a", fixture.bytes)
        #expect(result.count == fixture.bytes.count)
        #expect(chunkOffsets(in: result) == fixture.chunkOffsets)
        let media = try #require(try await readMP4(result))
        #expect(media.genre == "Pop")
    }

    @Test func moovAfterMdatNeedsNoOffsetChanges() async throws {
        let fixture = mp4File(items: mp4Items(), moovLast: true)
        let longGenre = String(repeating: "Progressive ", count: 20) + "Rock"
        let result = try rewritten(TagEdits(genre: longGenre), "song.m4a", fixture.bytes)
        #expect(chunkOffsets(in: result) == fixture.chunkOffsets)
        #expect(Array(result.prefix(fixture.moovStart)) == Array(fixture.bytes.prefix(fixture.moovStart)))
        let media = try #require(try await readMP4(result))
        #expect(media.genre == longGenre)
        #expect(media.trackNumber == 3)
    }

    @Test func missingUserDataIsCreated() async throws {
        let fixture = mp4File(items: nil)
        let result = try rewritten(TagEdits(album: "Nocturne Drift", genre: "Ambient"), "song.m4a", fixture.bytes)
        let media = try #require(try await readMP4(result))
        #expect(media.genre == "Ambient")
        #expect(media.album == "Nocturne Drift")
        #expect(media.duration == 90)
        let shifted = chunkOffsets(in: result)
        for offset in shifted { #expect(chunkBytes(in: result, at: offset) == mp4Chunk) }
    }

    @Test func predefinedGenreNumberBecomesText() async throws {
        let predefined = atom("gnre", atom("data", be32(0) + be32(0) + [0, 18]))
        let fixture = mp4File(items: mp4Items(genre: predefined), freeSize: 300)
        let before = try #require(try await readMP4(fixture.bytes))
        #expect(before.genre == "Rock")
        #expect(try plan(TagEdits(genre: "Rock"), "song.m4a", fixture.bytes) == nil)
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.m4a", fixture.bytes)
        let media = try #require(try await readMP4(result))
        #expect(media.genre == "Ambient")
        let moov = Array(result[fixture.moovStart..<fixture.moovStart + fixture.moovLength])
        #expect(!moov.indices.dropLast(3).contains { Array(moov[$0..<$0 + 4]) == Array("gnre".utf8) })
    }

    @Test func fragmentedMoviesAreRefused() throws {
        let fragmented = mp4File(items: mp4Items(), extraTopLevel: atom("moof", zeros(8)))
        #expect(throws: TagWriteError.unsupportedLayout("fragmented MPEG-4")) { try plan(TagEdits(genre: "Ambient"), "song.m4a", fragmented.bytes) }
        let extended = mp4File(items: mp4Items(), extraMoovChildren: atom("mvex", zeros(8)))
        #expect(throws: TagWriteError.unsupportedLayout("fragmented MPEG-4")) { try plan(TagEdits(genre: "Ambient"), "song.m4a", extended.bytes) }
    }

    @Test func valuesAlreadyInPlaceNeedNoRewrite() throws {
        let fixture = mp4File(items: mp4Items())
        #expect(try plan(TagEdits(genre: "Rock"), "song.m4a", fixture.bytes) == nil)
        #expect(try plan(TagEdits(album: "Nocturne Drift"), "song.m4a", fixture.bytes) == nil)
    }

    @Test func discMarkerInTheAlbumTagSurvivesARename() async throws {
        let fixture = mp4File(items: mp4Items(album: "Live Sessions [CD 2]"), freeSize: 200)
        let result = try rewritten(TagEdits(album: "Live at Halden"), "song.m4a", fixture.bytes)
        let media = try #require(try await readMP4(result))
        #expect(media.album == "Live at Halden [CD 2]")
        #expect(media.genre == "Rock")
    }

    @Test func malformedContainersAreRefused() throws {
        let truncated = Array(mp4File(items: mp4Items()).bytes.dropLast(50))
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.m4a", truncated) }
        let oversized = atom("ftyp", Array("M4A ".utf8) + be32(0)) + be32(0x7FFF_FFFF) + Array("moov".utf8) + zeros(100)
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.m4a", oversized) }
        #expect(throws: TagWriteError.mismatchedContents("not an MPEG-4 container")) { try plan(TagEdits(genre: "Ambient"), "song.m4a", mpegAudio) }
    }
}

// MARK: - FLAC fixtures

private nonisolated func flacBlock(_ type: Int, _ data: [UInt8], last: Bool = false) -> [UInt8] {
    [UInt8(type) | (last ? 0x80 : 0), UInt8((data.count >> 16) & 0xFF), UInt8((data.count >> 8) & 0xFF), UInt8(data.count & 0xFF)] + data
}

private nonisolated func vorbis(_ comments: [String], vendor: String = "reference libFLAC 1.4.3") -> [UInt8] {
    var block = le32(vendor.utf8.count) + Array(vendor.utf8) + le32(comments.count)
    for comment in comments { block += le32(comment.utf8.count) + Array(comment.utf8) }
    return block
}

private nonisolated let streamInfo: [UInt8] = {
    var block = zeros(34)
    block[0] = 0x10; block[1] = 0x00; block[2] = 0x10; block[3] = 0x00
    // 44100 Hz, 2 channels, 16 bits, 441000 samples.
    block[10] = 0x0A; block[11] = 0xC4; block[12] = 0x42; block[13] = 0xF0
    block[14] = 0x06; block[15] = 0xBA; block[16] = 0xA8
    return block
}()

private nonisolated let flacAudio: [UInt8] = [0xFF, 0xF8, 0x69, 0x08] + (0..<500).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) }

private nonisolated func flacPicture() -> [UInt8] {
    let mime = Array("image/png".utf8)
    return be32(3) + be32(mime.count) + mime + be32(0) + zeros(16) + be32(pictureBytes.count) + pictureBytes
}

private nonisolated func flacFile(comments: [String]? = ["TITLE=Morning", "ARTIST=Halden Vey", "ALBUM=Nocturne Drift", "GENRE=Rock", "TRACKNUMBER=3"], padding: Int? = 256, picture: Bool = true) -> [UInt8] {
    var blocks: [(Int, [UInt8])] = [(0, streamInfo)]
    if let comments { blocks.append((4, vorbis(comments))) }
    if picture { blocks.append((6, flacPicture())) }
    if let padding { blocks.append((1, zeros(padding))) }
    var file = Array("fLaC".utf8)
    for (index, block) in blocks.enumerated() { file += flacBlock(block.0, block.1, last: index == blocks.count - 1) }
    return file + flacAudio
}

private nonisolated func flacInfo(_ bytes: [UInt8]) throws -> FLACInfo {
    try #require(FLACHeader.parse(Data(bytes)))
}

private nonisolated func flacHeaderLength(_ bytes: [UInt8]) -> Int { bytes.count - flacAudio.count }

private nonisolated func vorbisEntries(_ bytes: [UInt8]) -> [String] {
    var offset = 4
    while offset + 4 <= bytes.count {
        let header = bytes[offset]
        let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        let start = offset + 4
        if header & 0x7F == 4 {
            let block = Array(bytes[start..<start + length])
            var position = 0
            func u32() -> Int { defer { position += 4 }; return Int(block[position]) | Int(block[position + 1]) << 8 | Int(block[position + 2]) << 16 | Int(block[position + 3]) << 24 }
            position += u32()
            let count = u32()
            return (0..<count).map { _ in
                let length = u32()
                defer { position += length }
                return String(decoding: block[position..<position + length], as: UTF8.self)
            }
        }
        offset = start + length
        if header & 0x80 != 0 { break }
    }
    return []
}

// MARK: - FLAC

@Suite struct FLACTagWriterTests {
    @Test func genreRewriteIsAbsorbedByPaddingSoTheAudioStaysPut() throws {
        let file = flacFile()
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.flac", file)
        #expect(result.count == file.count)
        #expect(Array(result.suffix(flacAudio.count)) == flacAudio)
        let info = try flacInfo(result)
        #expect(info.tag("GENRE") == "Ambient")
        #expect(info.tag("TITLE") == "Morning")
        #expect(info.tag("ARTIST") == "Halden Vey")
        #expect(info.tag("ALBUM") == "Nocturne Drift")
        #expect(info.number("TRACKNUMBER") == 3)
        #expect(info.picture == Data(pictureBytes))
        #expect(info.sampleRate == 44_100)
        #expect(info.neededPrefix == nil)
        #expect(vorbisEntries(result) == ["TITLE=Morning", "ARTIST=Halden Vey", "ALBUM=Nocturne Drift", "GENRE=Ambient", "TRACKNUMBER=3"])
    }

    @Test func headerGrowsWhenThereIsNoPaddingToUse() throws {
        let file = flacFile(padding: nil)
        let longGenre = String(repeating: "Progressive ", count: 20) + "Rock"
        let result = try rewritten(TagEdits(genre: longGenre), "song.flac", file)
        #expect(result.count > file.count)
        #expect(Array(result.suffix(flacAudio.count)) == flacAudio)
        #expect(flacHeaderLength(result) - flacHeaderLength(file) >= FLACTagWriter.growthPadding)
        let info = try flacInfo(result)
        #expect(info.tag("GENRE") == longGenre)
        #expect(info.picture == Data(pictureBytes))
        // The padding block that was added is the last block.
        let header = Array(result.prefix(flacHeaderLength(result)))
        let lastBlockType = header[flacHeaderLength(result) - FLACTagWriter.growthPadding - 4]
        #expect(lastBlockType == 0x81)
    }

    @Test func lowercaseAndRepeatedKeysCollapseToOneEntry() throws {
        let file = flacFile(comments: ["TITLE=Morning", "genre=Rock", "Genre=Pop", "ALBUM=Nocturne Drift"])
        let result = try rewritten(TagEdits(genre: "Ambient"), "song.flac", file)
        #expect(vorbisEntries(result) == ["TITLE=Morning", "GENRE=Ambient", "ALBUM=Nocturne Drift"])
        #expect(try flacInfo(result).tag("GENRE") == "Ambient")
    }

    @Test func missingCommentBlockIsCreatedAfterStreamInfo() throws {
        let file = flacFile(comments: nil, padding: nil, picture: false)
        let result = try rewritten(TagEdits(album: "Nocturne Drift", genre: "Ambient"), "song.flac", file)
        #expect(result[4] & 0x7F == 0)
        #expect(result[4 + 4 + streamInfo.count] & 0x7F == 4)
        let info = try flacInfo(result)
        #expect(info.tag("GENRE") == "Ambient")
        #expect(info.tag("ALBUM") == "Nocturne Drift")
        #expect(info.sampleRate == 44_100)
        #expect(Array(result.suffix(flacAudio.count)) == flacAudio)
    }

    @Test func valuesAlreadyInPlaceNeedNoRewrite() throws {
        let file = flacFile()
        #expect(try plan(TagEdits(genre: "Rock"), "song.flac", file) == nil)
        let lowercase = flacFile(comments: ["genre=Rock"])
        #expect(try plan(TagEdits(genre: "Rock"), "song.flac", lowercase) == nil)
    }

    @Test func discMarkerInTheAlbumTagSurvivesARename() throws {
        let file = flacFile(comments: ["ALBUM=Live Sessions - Disc 2", "GENRE=Rock"])
        let result = try rewritten(TagEdits(album: "Live at Halden"), "song.flac", file)
        #expect(try flacInfo(result).tag("ALBUM") == "Live at Halden - Disc 2")
    }

    @Test func exactFitWithoutPaddingKeepsTheSize() throws {
        let file = flacFile(comments: ["GENRE=Rock"], padding: nil, picture: false)
        let result = try rewritten(TagEdits(genre: "Jazz"), "song.flac", file)
        #expect(result.count == file.count)
        #expect(try flacInfo(result).tag("GENRE") == "Jazz")
    }

    @Test func brokenBlocksAreRefused() throws {
        let truncated = Array(flacFile(padding: nil).prefix(60))
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.flac", truncated) }
        var twoComments = Array("fLaC".utf8) + flacBlock(0, streamInfo) + flacBlock(4, vorbis(["GENRE=Rock"])) + flacBlock(4, vorbis(["GENRE=Pop"]), last: true)
        twoComments += flacAudio
        #expect(throws: TagWriteError.self) { try plan(TagEdits(genre: "Ambient"), "song.flac", twoComments) }
        #expect(throws: TagWriteError.mismatchedContents("not a FLAC stream")) { try plan(TagEdits(genre: "Ambient"), "song.flac", mpegAudio) }
    }
}

// MARK: - Shared behaviour

@Suite struct TagWriterDispatchTests {
    @Test func unsupportedFormatsFailBeforeAnyByteIsRead() throws {
        var reads = 0
        let error = #expect(throws: TagWriteError.self) {
            try TagWriter.plan(edits: TagEdits(genre: "Ambient"), fileName: "song.wav", fileSize: 1000) { _ in reads += 1; return Data() }
        }
        #expect(error == .unsupportedFormat("wav"))
        #expect(reads == 0)
        #expect(!TagWriter.supports(fileName: "song.ogg"))
        #expect(TagWriter.supports(fileName: "Song.FLAC"))
    }

    @Test func albumValueCarriesDiscMarkersOnlyWhenTheNewTitleHasNone() {
        let edits = TagEdits(album: "Concert")
        #expect(edits.albumValue(replacing: "Live (Disc 2)") == "Concert (Disc 2)")
        #expect(edits.albumValue(replacing: "Live") == "Concert")
        #expect(edits.albumValue(replacing: nil) == "Concert")
        #expect(TagEdits(album: "Concert (Disc 3)").albumValue(replacing: "Live (Disc 2)") == "Concert (Disc 3)")
        #expect(TagEdits(album: "  ").album == nil)
        #expect(TagEdits().isEmpty)
    }

    @Test func plansAssembleToFilesOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-tagwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "song.flac")
        let destination = directory.appending(path: "patched.flac")
        let original = flacFile()
        try Data(original).write(to: source)
        #expect(try TagWriter.rewrite(edits: TagEdits(genre: "Ambient"), fileName: "song.flac", source: source, destination: destination))
        let written = [UInt8](try Data(contentsOf: destination))
        #expect(written == (try rewritten(TagEdits(genre: "Ambient"), "song.flac", original)))
        #expect(try !TagWriter.rewrite(edits: TagEdits(genre: "Rock"), fileName: "song.flac", source: source, destination: destination))
    }

    @Test func rewrittenFilesReadBackWithTheIndexersParsers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-tagwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files: [(String, [UInt8])] = [
            ("song.mp3", id3Tag(version: 3, frames: standardFrames(version: 3), padding: 64) + mpegAudio),
            ("song.m4a", mp4File(items: mp4Items(), freeSize: 200).bytes),
            ("song.flac", flacFile()),
        ]
        for (name, bytes) in files {
            let url = directory.appending(path: name)
            try Data(try rewritten(TagEdits(genre: "Ambient"), name, bytes)).write(to: url)
            let tags = try #require(try await TagWriter.readBack(fileName: name, at: url))
            #expect(tags.genre == "Ambient")
            #expect(tags.title == "Morning")
            #expect(tags.album == "Nocturne Drift")
            #expect(tags.trackNumber == 3)
        }
    }
}
