import CryptoKit
import Foundation

/// A person using the app. Kept on the device for now and shaped as one record plus one state
/// document, so the same data can move to a CloudKit family zone later without changing screens.
public nonisolated struct Profile: Codable, Identifiable, Hashable, Sendable {
    public nonisolated enum Role: String, Codable, Sendable {
        case owner, member
    }

    public var id: String
    public var name: String
    public var avatar: ProfileAvatar
    /// Set when the profile asks for a PIN before it opens.
    public var pin: PINRecord?
    public var role: Role
    public var createdAt: Date
    public var updatedAt: Date
    /// The iCloud user this profile belongs to, once it has synced from a device signed in as them.
    public var userRecordName: String? = nil

    public var isLocked: Bool { pin != nil }

    public nonisolated static let limit = 6

    public init(id: String, name: String, avatar: ProfileAvatar, pin: PINRecord?, role: Role, createdAt: Date, updatedAt: Date, userRecordName: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.pin = pin
        self.role = role
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userRecordName = userRecordName
    }
}

/// What a family shares besides its people: the server the music lives on, so a member's device can
/// connect without typing addresses.
public nonisolated struct FamilyInfo: Codable, Sendable, Equatable {
    public var name: String
    public var serverName: String
    public var serverAccount: String
    public var musicPath: String?
    public var updatedAt: Date
    /// A read-only account on the NAS made for the family, so members connect without the owner's password.
    public var familyAccount: String? = nil
    public var familyPassword: String? = nil
    /// The server's URL as the owner reaches it: a DDNS name, or an address on the home network.
    public var address: String? = nil

    public init(name: String, serverName: String, serverAccount: String, musicPath: String?, updatedAt: Date, familyAccount: String? = nil, familyPassword: String? = nil, address: String? = nil) {
        self.name = name
        self.serverName = serverName
        self.serverAccount = serverAccount
        self.musicPath = musicPath
        self.updatedAt = updatedAt
        self.familyAccount = familyAccount
        self.familyPassword = familyPassword
        self.address = address
    }

    /// Whether members have a way to reach the server at all.
    public var isReachable: Bool { address != nil }

    /// The same server details, whatever the timestamps say.
    public func describesSameServer(as other: FamilyInfo) -> Bool {
        name == other.name && address == other.address && serverName == other.serverName
            && serverAccount == other.serverAccount && musicPath == other.musicPath
            && familyAccount == other.familyAccount && familyPassword == other.familyPassword
    }
}

/// The family's read-only NAS account as kept by the owner's device.
public nonisolated struct FamilyAccess: Sendable, Equatable {
    public var account: String
    public var password: String

    public init(account: String, password: String) {
        self.account = account
        self.password = password
    }
}

/// A photo when the person picked one, otherwise their initials on a colour chosen for them.
/// `symbol` is kept for profiles made before photos existed.
public nonisolated struct ProfileAvatar: Codable, Hashable, Sendable {
    public var symbol: String
    public var colorHex: String
    /// Counts photo changes, so screens and other devices know when to load it again; nil means no photo.
    public var photoVersion: Int? = nil

    public var hasPhoto: Bool { photoVersion != nil }

    public init(symbol: String, colorHex: String, photoVersion: Int? = nil) {
        self.symbol = symbol
        self.colorHex = colorHex
        self.photoVersion = photoVersion
    }

    /// "Ana Kestrel" → "AK", "Me" → "M".
    public static func initials(for name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    public static let symbols = [
        "music.note", "headphones", "guitars.fill", "pianokeys", "music.mic", "waveform",
        "star.fill", "heart.fill", "sparkles", "moon.stars.fill", "sun.max.fill", "bolt.fill",
        "leaf.fill", "flame.fill", "snowflake", "pawprint.fill", "gamecontroller.fill", "airplane",
        "sailboat.fill", "bicycle", "cup.and.saucer.fill", "camera.fill", "book.fill", "globe.europe.africa.fill",
    ]

    public static let colors = [
        "#d4234f", "#e07a2f", "#d4a017", "#5c9e1c", "#0d9488", "#2a9dd6",
        "#4a2fd6", "#8f7dff", "#c93a7a", "#b8622e", "#1f3a8a", "#3d4a5c",
    ]

    public static func random() -> ProfileAvatar {
        ProfileAvatar(symbol: symbols.randomElement() ?? "music.note", colorHex: colors.randomElement() ?? "#4a2fd6")
    }
}

/// A salted hash of a four digit PIN; the PIN itself is never stored.
public nonisolated struct PINRecord: Codable, Hashable, Sendable {
    public let salt: String
    public let hash: String

    public static func make(_ pin: String) -> PINRecord {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        return PINRecord(salt: salt, hash: digest(salt: salt, pin: pin))
    }

    public func matches(_ pin: String) -> Bool {
        hash == Self.digest(salt: salt, pin: pin)
    }

    private static func digest(salt: String, pin: String) -> String {
        SHA256.hash(data: Data((salt + ":" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a profile keeps for one library (one drive): favourites, plays, lists and searches.
public nonisolated struct LibraryState: Codable, Sendable, Equatable {
    public var favourites: [String] = []
    public var playlists: [LocalPlaylist] = []
    /// Track ids, newest first.
    public var played: [String] = []
    /// Album ids, newest first.
    public var recentAlbums: [String] = []
    public var searches: [String] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favourites = try container.decodeIfPresent([String].self, forKey: .favourites) ?? []
        playlists = try container.decodeIfPresent([LocalPlaylist].self, forKey: .playlists) ?? []
        played = try container.decodeIfPresent([String].self, forKey: .played) ?? []
        recentAlbums = try container.decodeIfPresent([String].self, forKey: .recentAlbums) ?? []
        searches = try container.decodeIfPresent([String].self, forKey: .searches) ?? []
    }
}

/// A profile's preferences, the same on every library.
public nonisolated struct ProfileSettings: Codable, Sendable, Equatable {
    public var quality = "Lossless"
    public var gapless = true
    public var appearance = "Auto"
    public var hidesBracketedTitleParts = false
    public var repeatMode = "off"
    public var shuffle = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? "Lossless"
        gapless = try container.decodeIfPresent(Bool.self, forKey: .gapless) ?? true
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "Auto"
        hidesBracketedTitleParts = try container.decodeIfPresent(Bool.self, forKey: .hidesBracketedTitleParts) ?? false
        repeatMode = try container.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
        shuffle = try container.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
    }
}

/// Everything a profile saves, as one document: last write wins by `updatedAt` once it syncs.
public nonisolated struct ProfileState: Codable, Sendable {
    /// Keyed by drive id; the sample library uses "".
    public var libraries: [String: LibraryState] = [:]
    public var settings = ProfileSettings()
    public var updatedAt = Date.distantPast

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraries = try container.decodeIfPresent([String: LibraryState].self, forKey: .libraries) ?? [:]
        settings = try container.decodeIfPresent(ProfileSettings.self, forKey: .settings) ?? ProfileSettings()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}
