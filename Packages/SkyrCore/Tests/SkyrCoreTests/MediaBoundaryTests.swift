import Foundation
import Testing
@testable import SkyrCore

@Test func mediaBoundsChecksBeforeArithmetic() {
    #expect(MediaBounds.contains(0, 0, end: 0))
    #expect(MediaBounds.contains(4, 8, end: 12))
    #expect(!MediaBounds.contains(4, 9, end: 12))
    #expect(!MediaBounds.contains(-1, 1, end: 12))
    #expect(!MediaBounds.contains(1, -1, end: 12))
    #expect(!MediaBounds.contains(Int.max, 1, end: Int.max))
    #expect(!MediaBounds.contains(0, Int.max, end: -1))
    #expect(MediaBounds.range(Int64.max - 4, length: 4)?.upperBound == Int64.max)
    #expect(MediaBounds.range(Int64.max, length: 1) == nil)
    #expect(MediaBounds.range(-1, length: 4) == nil)
    #expect(MediaBounds.positiveInteger(UInt64.max) == nil)
    #expect(MediaBounds.positiveInteger(UInt64(Int.max)) == Int.max)
    #expect(MediaBounds.bitrate(bytes: 16_000, duration: 1) == 128_000)
    #expect(MediaBounds.bitrate(bytes: Int64.max, duration: 0.001) == nil)
    #expect(MediaBounds.bitrate(bytes: -1, duration: 1) == nil)
    #expect(MediaBounds.bitrate(bytes: 16_000, duration: .infinity) == nil)
}

@Test func primitiveReadersAcceptOnlyAvailableSpans() {
    let bytes: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 2]
    #expect(MP4Tags.u64(bytes, 0) == 4_294_967_298)
    #expect(MP4Tags.u32(bytes, 4) == 2)
    #expect(MP4Tags.u16(bytes, 6) == 2)
    #expect(MP4Tags.u64(bytes, -1) == 0)
    #expect(MP4Tags.u32(bytes, Int.max) == 0)
    #expect(MP4Tags.fourCC(bytes, Int.max) == "")
    #expect(ID3Tags.syncsafe(bytes, -1) == 0)
}

@Test(arguments: [0, 1, 2]) func validMP4BoxWidthsAndEOFSizePreserveTags(_ mode: Int) async throws {
    var header = [UInt8](repeating: 0, count: 100)
    header.replaceSubrange(12..<16, with: bigEndian(1000))
    header.replaceSubrange(16..<20, with: bigEndian(90_000))
    let title = atom("©nam", atom("data", bigEndian(1) + bigEndian(0) + Array("Morning".utf8)))
    let track = atom("trkn", atom("data", bigEndian(0) + bigEndian(0) + [0, 0, 0, 3, 0, 12, 0, 0]))
    let metadata = atom("meta", [0, 0, 0, 0] + atom("ilst", title + track))
    let movie = atom("mvhd", header) + atom("udta", metadata)
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + atom("moov", movie, mode: mode)
    let media = try #require(try await MP4Tags.read { range in fixtureRead(file, range) })
    #expect(media.title == "Morning")
    #expect(media.trackNumber == 3)
    #expect(media.duration == 90)
}

@Test func validAudioDescriptorKeepsCodecRateAndBitrate() async throws {
    var sample = [UInt8](repeating: 0, count: 28)
    sample.replaceSubrange(16..<20, with: [0, 2, 0, 16])
    sample.replaceSubrange(24..<28, with: bigEndian(44_100 << 16))
    let config: [UInt8] = [0x40, 0x15, 0, 0, 0] + bigEndian(128_000) + bigEndian(128_000)
    let es: [UInt8] = [0x03, 18, 0, 1, 0, 0x04, 13] + config
    sample += atom("esds", [0, 0, 0, 0] + es)
    let stsd = atom("stsd", [0, 0, 0, 0] + bigEndian(1) + atom("mp4a", sample))
    let track = atom("trak", atom("mdia", atom("minf", atom("stbl", stsd))))
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + atom("moov", track)
    let media = try #require(try await MP4Tags.read { range in fixtureRead(file, range) })
    #expect(media.codec == "aac")
    #expect(media.sampleRate == 44_100)
    #expect(media.bitrate == 128_000)
}

@Test func validVersionOneMovieBeyondHeadPreservesDurationAndArtwork() async throws {
    var header = [UInt8](repeating: 0, count: 112)
    header[0] = 1
    header.replaceSubrange(20..<24, with: bigEndian(1000))
    header.replaceSubrange(24..<32, with: bigEndian(0) + bigEndian(90_000))
    let picture = [UInt8](Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!)
    let cover = atom("covr", atom("data", bigEndian(14) + bigEndian(0) + picture))
    let movie = atom("mvhd", header) + atom("meta", [0, 0, 0, 0] + atom("ilst", cover))
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
        + atom("free", [UInt8](repeating: 0, count: 65_536)) + atom("moov", movie)
    let media = try #require(try await MP4Tags.read { range in fixtureRead(file, range) })
    #expect(media.duration == 90)
    #expect(media.artwork == Data(picture))
}

@Test func validAppleLosslessSamplePreservesFormatDetails() async throws {
    var sample = [UInt8](repeating: 0, count: 28)
    sample.replaceSubrange(16..<20, with: [0, 2, 0, 24])
    var cookie = [UInt8](repeating: 0, count: 24)
    cookie[5] = 24
    cookie.replaceSubrange(16..<20, with: bigEndian(900_000))
    cookie.replaceSubrange(20..<24, with: bigEndian(96_000))
    sample += atom("alac", [0, 0, 0, 0] + cookie)
    let stsd = atom("stsd", [0, 0, 0, 0] + bigEndian(1) + atom("alac", sample))
    let track = atom("trak", atom("mdia", atom("minf", atom("stbl", stsd))))
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + atom("moov", track)
    let media = try #require(try await MP4Tags.read { range in fixtureRead(file, range) })
    #expect(media.codec == "alac")
    #expect(media.bitsPerChannel == 24)
    #expect(media.sampleRate == 96_000)
    #expect(media.bitrate == 900_000)
}

@Test(arguments: [3, 4]) func validID3GroupingAndExtendedHeadersPreserveText(_ version: Int) async throws {
    let text: [UInt8] = [version == 4 ? 3 : 0] + Array("Morning".utf8)
    let prefix: [UInt8] = version == 4 ? [1] + syncsafeBytes(text.count) : [1]
    let payload = prefix + text
    let frame = Array("TIT2".utf8) + (version == 4 ? syncsafeBytes(payload.count) : bigEndian(UInt32(payload.count)))
        + [0, version == 4 ? 0x41 : 0x20] + payload
    let extended: [UInt8] = version == 4 ? syncsafeBytes(6) + [1, 0] : bigEndian(6) + [0, 0, 0, 0, 0, 0]
    let tag = extended + frame
    let file = Array("ID3".utf8) + [UInt8(version), 0, 0x40] + syncsafeBytes(tag.count) + tag
        + [0xFF, 0xFB, 0x90, 0] + [UInt8](repeating: 0, count: 100)
    let media = try #require(try await ID3Tags.read(fileSize: 1_000_000) { range in fixtureRead(file, range) })
    #expect(media.title == "Morning")
    #expect(media.codec == "mp3")
    #expect(media.sampleRate == 44_100)
    #expect(media.bitrate == 128_000)
    #expect((media.duration ?? 0) > 0)
}

@Test func untaggedMPEGHeaderRemainsSupported() async throws {
    let file: [UInt8] = [0xFF, 0xFB, 0x90, 0]
    let media = try #require(try await ID3Tags.read(fileSize: 16_000) { range in fixtureRead(file, range) })
    #expect(media.codec == "mp3")
    #expect(media.duration == 1)
}

// MARK: - Security: Malformed Metadata Rejection

@Test func mp4OversizedMoovDeclarationIsRejected() async throws {
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
        + bigEndian(0x7FFF_FFFF) + Array("moov".utf8) + [UInt8](repeating: 0, count: 100)
    let media = try await MP4Tags.read { range in fixtureRead(file, range) }
    #expect(media == nil)
}

@Test func mp4TruncatedBoxHeaderIsRejected() async throws {
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + [0, 0, 0, 20]
    let media = try await MP4Tags.read { range in fixtureRead(file, range) }
    #expect(media == nil)
}

@Test func mp4AtomSizeSmallerThanHeaderIsRejected() async throws {
    let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
        + [0, 0, 0, 4] + Array("moov".utf8)
    let media = try await MP4Tags.read { range in fixtureRead(file, range) }
    #expect(media == nil)
}

@Test func id3OversizedTagDeclarationIsRejected() async throws {
    let file = Array("ID3".utf8) + [4, 0, 0] + syncsafeBytes(0x0FFF_FFFF) + [UInt8](repeating: 0, count: 100)
    let media = try await ID3Tags.read(fileSize: 1_000_000) { range in fixtureRead(file, range) }
    #expect(media == nil)
}

@Test func id3TruncatedFrameDataIsRejected() async throws {
    let frame = Array("TIT2".utf8) + syncsafeBytes(1000) + [0, 0]
    let file = Array("ID3".utf8) + [4, 0, 0] + syncsafeBytes(frame.count) + frame
    let media = try await ID3Tags.read(fileSize: 1_000_000) { range in fixtureRead(file, range) }
    #expect(media?.title == nil)
}

@Test func id3OversizedExtendedHeaderIsRejected() async throws {
    let file = Array("ID3".utf8) + [4, 0, 0x40] + syncsafeBytes(100) + syncsafeBytes(0x0FFF_FFFF) + [UInt8](repeating: 0, count: 90)
    let media = try await ID3Tags.read(fileSize: 1_000_000) { range in fixtureRead(file, range) }
    #expect(media?.title == nil)
}

@Test func flacOversizedBlockDeclarationIsRejected() {
    var file = Array("fLaC".utf8)
    file += [0x00, 0xFF, 0xFF, 0xFF]
    let info = FLACHeader.parse(Data(file))
    #expect(info?.neededPrefix == nil || info?.sampleRate == nil)
}

@Test func flacOversizedVorbisVendorLengthIsRejected() {
    var file = Array("fLaC".utf8)
    file += [0x00, 0x00, 0x00, 18]
    file += [UInt8](repeating: 0, count: 18)
    file += [0x84]
    file += [0x00, 0x00, 10]
    file += [0xFF, 0xFF, 0xFF, 0x7F]
    let info = FLACHeader.parse(Data(file))
    #expect(info?.tags.isEmpty ?? true)
}

@Test func flacOversizedPictureDescriptionLengthIsRejected() {
    var file = Array("fLaC".utf8)
    file += [0x00, 0x00, 0x00, 18]
    file += [UInt8](repeating: 0, count: 18)
    file += [0x86]
    file += [0x00, 0x00, 30]
    file += [0x00, 0x00, 0x00, 0x03]
    file += [0x00, 0x00, 0x00, 0x00]
    file += [0x7F, 0xFF, 0xFF, 0xFF]
    let info = FLACHeader.parse(Data(file))
    #expect(info?.picture == nil)
}

@Test func flacTruncatedPictureMetadataFieldsAreRejected() {
    var file = Array("fLaC".utf8)
    file += [0x00, 0x00, 0x00, 18]
    file += [UInt8](repeating: 0, count: 18)
    file += [0x86]
    file += [0x00, 0x00, 20]
    file += [0x00, 0x00, 0x00, 0x03]
    file += [0x00, 0x00, 0x00, 0x04]
    file += Array("test".utf8)
    file += [0x00, 0x00, 0x00, 0x00]
    let info = FLACHeader.parse(Data(file))
    #expect(info?.picture == nil)
}

private nonisolated func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private nonisolated func atom(_ type: String, _ payload: [UInt8], mode: Int = 0) -> [UInt8] {
    let name = [UInt8](type.data(using: .isoLatin1)!)
    if mode == 1 { return bigEndian(1) + name + bigEndian(0) + bigEndian(UInt32(payload.count + 16)) + payload }
    return bigEndian(mode == 2 ? 0 : UInt32(payload.count + 8)) + name + payload
}

private nonisolated func syncsafeBytes(_ value: Int) -> [UInt8] {
    [UInt8((value >> 21) & 127), UInt8((value >> 14) & 127), UInt8((value >> 7) & 127), UInt8(value & 127)]
}

private nonisolated func fixtureRead(_ bytes: [UInt8], _ range: Range<Int64>) -> Data {
    let start = min(bytes.count, Int(range.lowerBound))
    let end = min(bytes.count, Int(range.upperBound))
    return Data(bytes[start..<end])
}
