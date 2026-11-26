import Foundation

/// SoundCloud ids are numbers for tracks, users and playlists, but strings for system playlists
/// ("soundcloud:system-playlists:..."), so playlist ids decode from either.
struct FlexID: Codable, Hashable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            value = String(i)
        } else {
            value = try c.decode(String.self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let i = Int(value) { try c.encode(i) } else { try c.encode(value) }
    }
}

struct SCUser: Codable, Identifiable, Hashable {
    let id: Int
    let username: String?
    let avatarUrl: String?
    let fullName: String?
    let followersCount: Int?
    let followingsCount: Int?
    let trackCount: Int?
    let playlistCount: Int?
    let permalinkUrl: String?
    let description: String?
    let city: String?
    let verified: Bool?

    static func == (a: SCUser, b: SCUser) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var name: String { username ?? "—" }

    func avatar(_ size: String = "t500x500") -> URL? { scImage(avatarUrl, size) }
}

struct SCFormat: Codable, Hashable {
    let proto: String?
    let mimeType: String?

    enum CodingKeys: String, CodingKey {
        case proto = "protocol"
        case mimeType
    }
}

struct SCTranscoding: Codable, Hashable {
    let url: String
    let preset: String?
    let snipped: Bool?
    let format: SCFormat?
    let quality: String?
}

struct SCMedia: Codable, Hashable {
    let transcodings: [SCTranscoding]
}

struct SCTrack: Codable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let duration: Int?
    let fullDuration: Int?
    let artworkUrl: String?
    let user: SCUser?
    let media: SCMedia?
    let trackAuthorization: String?
    let policy: String?
    let permalinkUrl: String?
    let playbackCount: Int?
    let likesCount: Int?
    let repostsCount: Int?
    let genre: String?
    let createdAt: String?
    let description: String?

    static func == (a: SCTrack, b: SCTrack) -> Bool { a.id == b.id && (a.title == nil) == (b.title == nil) }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Playlists return only the first few tracks in full; the rest are `{id, kind, policy}` stubs.
    var isStub: Bool { title == nil }

    /// Go+ tracks without a subscription only stream a 30 s preview.
    var isSnipped: Bool {
        if policy == "SNIP" { return true }
        if let t = media?.transcodings, !t.isEmpty { return t.allSatisfy { $0.snipped == true } }
        return false
    }

    var seconds: Double { Double(fullDuration ?? duration ?? 0) / 1000 }

    func artwork(_ size: String = "t500x500") -> URL? {
        scImage(artworkUrl ?? user?.avatarUrl, size)
    }
}

struct SCPlaylist: Codable, Identifiable, Hashable {
    let id: FlexID
    let title: String?
    let artworkUrl: String?
    let calculatedArtworkUrl: String?
    let user: SCUser?
    let trackCount: Int?
    let tracks: [SCTrack]?
    let duration: Int?
    let kind: String?
    let urn: String?
    let isAlbum: Bool?
    let permalinkUrl: String?
    let shortDescription: String?
    let description: String?

    static func == (a: SCPlaylist, b: SCPlaylist) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isSystem: Bool { kind == "system-playlist" || (urn?.contains("system-playlists") ?? false) }

    func artwork(_ size: String = "t500x500") -> URL? {
        scImage(artworkUrl ?? calculatedArtworkUrl ?? tracks?.first(where: { $0.artworkUrl != nil })?.artworkUrl ?? user?.avatarUrl, size)
    }
}

struct SCPage<T: Decodable>: Decodable {
    let collection: [T]
    let nextHref: String?
}

struct SCSelection: Decodable, Identifiable {
    let id: String?
    let urn: String?
    let title: String?
    let description: String?
    let items: SCPage<SCPlaylist>?

    var key: String { id ?? urn ?? title ?? UUID().uuidString }
}

struct SCLikeItem: Decodable { let track: SCTrack? }
struct SCChartItem: Decodable { let track: SCTrack? }
struct SCHistoryItem: Decodable { let track: SCTrack? }

struct SCStreamItem: Decodable {
    let type: String?
    let track: SCTrack?
    let playlist: SCPlaylist?
    let user: SCUser?
}

struct SCLibraryItem: Decodable {
    let type: String?
    let playlist: SCPlaylist?
    let systemPlaylist: SCPlaylist?
}

/// SoundCloud image URLs end in `-large.jpg` (100 px); the size suffix picks another rendition.
func scImage(_ s: String?, _ size: String) -> URL? {
    guard let s, !s.isEmpty else { return nil }
    return URL(string: s.replacingOccurrences(of: "-large.", with: "-\(size)."))
}
