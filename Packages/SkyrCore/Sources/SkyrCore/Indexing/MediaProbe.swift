import AVFoundation
import Foundation

/// Tags, duration and stream details read with AVFoundation, for formats other than FLAC.
public nonisolated struct ProbedMedia: Sendable {
    public var duration: TimeInterval?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var artwork: Data?
    public var sampleRate: Int?
    public var bitsPerChannel: Int?
    public var bitrate: Int?
    public var codec: String?
}

public nonisolated enum MediaProbe {
    public static func probe(url: URL) async -> ProbedMedia {
        var result = ProbedMedia()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
            result.duration = duration.seconds
        }

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle: result.title = try? await item.load(.stringValue)
                case .commonKeyArtist: result.artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName: result.album = try? await item.load(.stringValue)
                case .commonKeyType: result.genre = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let text = try? await item.load(.stringValue) { result.year = Int(text.prefix(4)) }
                case .commonKeyArtwork: result.artwork = try? await item.load(.dataValue)
                default: break
                }
            }
        }

        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let identifier = item.identifier else { continue }
                switch identifier {
                case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
                    result.trackNumber = await numberValue(of: item) ?? result.trackNumber
                case .id3MetadataPartOfASet, .iTunesMetadataDiscNumber:
                    result.discNumber = await numberValue(of: item) ?? result.discNumber
                case .id3MetadataBand, .iTunesMetadataAlbumArtist:
                    result.albumArtist = (try? await item.load(.stringValue)) ?? result.albumArtist
                case .id3MetadataContentType, .iTunesMetadataUserGenre:
                    if result.genre == nil { result.genre = try? await item.load(.stringValue) }
                case .iTunesMetadataPredefinedGenre:
                    if result.genre == nil { result.genre = await predefinedGenre(of: item) }
                case .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate:
                    if result.year == nil, let text = try? await item.load(.stringValue) { result.year = Int(text.prefix(4)) }
                default:
                    break
                }
            }
        }

        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if basic.mSampleRate > 0 { result.sampleRate = Int(basic.mSampleRate) }
                if basic.mBitsPerChannel > 0 { result.bitsPerChannel = Int(basic.mBitsPerChannel) }
                result.codec = codecName(basic.mFormatID)
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                result.bitrate = Int(rate)
            }
        }
        return result
    }

    /// Track and disc numbers arrive as "3/12" strings from ID3 or packed integers from iTunes atoms.
    private static func numberValue(of item: AVMetadataItem) async -> Int? {
        if let text = try? await item.load(.stringValue), let value = Int(text.split(separator: "/").first ?? "") {
            return value
        }
        if let number = try? await item.load(.numberValue) {
            return number.intValue
        }
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            return Int(data[2]) << 8 | Int(data[3])
        }
        return nil
    }

    /// The "gnre" atom holds an ID3v1 genre index plus one as two big-endian bytes; iTunes writes it
    /// instead of a genre string whenever the genre is one of the standard names.
    private static func predefinedGenre(of item: AVMetadataItem) async -> String? {
        if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
        var index: Int?
        if let number = try? await item.load(.numberValue) {
            index = number.intValue
        } else if let data = try? await item.load(.dataValue), data.count >= 2 {
            index = Int(data[data.count - 2]) << 8 | Int(data[data.count - 1])
        }
        guard let index, index >= 1, index <= id3Genres.count else { return nil }
        return id3Genres[index - 1]
    }

    static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic", "Bluegrass",
        "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic",
        "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove",
        "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore",
        "Terror", "Indie", "BritPop", "Afro-Punk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover",
        "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop",
    ]

    private static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatMPEGLayer3: "mp3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: "aac"
        case kAudioFormatAppleLossless: "alac"
        case kAudioFormatFLAC: "flac"
        case kAudioFormatLinearPCM: "pcm"
        case kAudioFormatOpus: "opus"
        default: ""
        }
    }
}
