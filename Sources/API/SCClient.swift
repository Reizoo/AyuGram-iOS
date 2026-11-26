import Foundation

enum SCError: LocalizedError {
    case noClientId
    case http(Int)
    case notLoggedIn
    case noStream
    case encrypted
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noClientId: return "Не удалось подключиться к SoundCloud (client_id)"
        case .http(let code): return "Ошибка SoundCloud (\(code))"
        case .notLoggedIn: return "Нужно войти в аккаунт SoundCloud"
        case .noStream: return "Этот трек нельзя воспроизвести"
        case .encrypted: return "Трек защищён (DRM), его нельзя воспроизвести"
        case .decoding(let s): return "Непонятный ответ SoundCloud: \(s)"
        }
    }
}

/// Client for SoundCloud's internal `api-v2`, the API the website itself uses. The public API no
/// longer registers apps, so the `client_id` is the website's own, read from its page.
actor SCClient {
    static let shared = SCClient()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private let api = "https://api-v2.soundcloud.com"
    private let session: URLSession
    private let decoder: JSONDecoder
    private var clientId: String? = UserDefaults.standard.string(forKey: "sc.clientId")
    private var clientIdTask: Task<String, Error>?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": SCClient.userAgent]
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: client_id

    private func ensureClientId() async throws -> String {
        if let c = clientId { return c }
        if let t = clientIdTask { return try await t.value }
        let t = Task { try await self.fetchClientId() }
        clientIdTask = t
        do {
            let c = try await t.value
            clientIdTask = nil
            clientId = c
            UserDefaults.standard.set(c, forKey: "sc.clientId")
            return c
        } catch {
            clientIdTask = nil
            throw error
        }
    }

    private func dropClientId() {
        clientId = nil
        UserDefaults.standard.removeObject(forKey: "sc.clientId")
    }

    private func fetchClientId() async throws -> String {
        var req = URLRequest(url: URL(string: "https://soundcloud.com/")!)
        req.setValue(SCClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        // The page hydrates its API client with the id.
        if let id = firstMatch(#""hydratable":"apiClient","data":\{"id":"([A-Za-z0-9]{32})""#, in: html) {
            return id
        }
        // Fallback: one of the page's script bundles carries it.
        let scripts = allMatches(#"https://a-v2\.sndcdn\.com/assets/[0-9A-Za-z_-]+\.js"#, in: html)
        for s in scripts.reversed() {
            guard let u = URL(string: s), let res = try? await session.data(from: u) else { continue }
            let js = String(decoding: res.0, as: UTF8.self)
            if let id = firstMatch(#"client_id[:=]"([A-Za-z0-9]{32})""#, in: js) { return id }
        }
        throw SCError.noClientId
    }

    // MARK: requests

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], auth: Bool = false) async throws -> T {
        let data = try await request("GET", path, query, auth: auth)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SCError.decoding(String(describing: error).prefix(200).description)
        }
    }

    @discardableResult
    func request(_ method: String, _ path: String, _ query: [String: String] = [:], auth: Bool = false, retried: Bool = false) async throws -> Data {
        let token = Keychain.token
        if auth && token == nil { throw SCError.notLoggedIn }
        let cid = try await ensureClientId()
        guard var comps = URLComponents(string: path.hasPrefix("http") ? path : api + path) else { throw SCError.http(0) }
        var items = (comps.queryItems ?? []).filter { $0.name != "client_id" && query[$0.name] == nil }
        items.append(URLQueryItem(name: "client_id", value: cid))
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { throw SCError.http(0) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        req.setValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/javascript, */*; q=0.1", forHTTPHeaderField: "Accept")
        if let token { req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization") }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (code == 401 || code == 403) && !retried {
            // The website rotates its client_id; read it again once.
            dropClientId()
            return try await request(method, path, query, auth: auth, retried: true)
        }
        if code == 401 && token != nil { throw SCError.notLoggedIn }
        guard (200..<300).contains(code) else { throw SCError.http(code) }
        return data
    }

    // MARK: streaming

    /// Resolves a playable URL: an HLS playlist (AAC preferred) or a progressive MP3.
    func streamURL(for t: SCTrack) async throws -> URL {
        var track = t
        if track.media == nil || track.trackAuthorization == nil {
            if let full = try await tracks(ids: [t.id]).first { track = full }
        }
        guard let all = track.media?.transcodings, !all.isEmpty else { throw SCError.noStream }

        func score(_ x: SCTranscoding) -> Int {
            let p = x.format?.proto ?? ""
            let mime = x.format?.mimeType ?? ""
            var s: Int
            switch p {
            case "hls": s = 100
            case "progressive": s = 90
            default: return -1 // encrypted-hls variants need DRM
            }
            if mime.contains("mp4a") || mime.contains("aac") { s += 6 }
            if x.quality == "hq" { s += 4 } else if x.quality == "sq" { s += 2 }
            if x.preset?.contains("160") == true { s += 1 }
            if x.snipped == true { s -= 50 }
            return s
        }
        let playable = all.filter { score($0) >= 0 }
        guard let best = playable.max(by: { score($0) < score($1) }) else { throw SCError.encrypted }

        var q: [String: String] = [:]
        if let a = track.trackAuthorization { q["track_authorization"] = a }
        struct R: Decodable { let url: String }
        let r: R = try await get(best.url, q)
        guard let u = URL(string: r.url) else { throw SCError.noStream }
        return u
    }

    // MARK: tracks

    func tracks(ids: [Int]) async throws -> [SCTrack] {
        var out: [Int: SCTrack] = [:]
        var i = 0
        while i < ids.count {
            let chunk = ids[i..<min(i + 50, ids.count)]
            let list: [SCTrack] = try await get("/tracks", ["ids": chunk.map(String.init).joined(separator: ",")])
            for t in list { out[t.id] = t }
            i += 50
        }
        return ids.compactMap { out[$0] }
    }

    /// Replaces playlist stubs with full tracks, keeping the order.
    func fill(_ list: [SCTrack]) async throws -> [SCTrack] {
        let stubs = list.filter { $0.isStub }.map { $0.id }
        if stubs.isEmpty { return list }
        let full = try await tracks(ids: stubs)
        var byId: [Int: SCTrack] = [:]
        for t in full { byId[t.id] = t }
        return list.compactMap { $0.isStub ? byId[$0.id] : $0 }
    }

    func related(_ trackId: Int) async throws -> [SCTrack] {
        let p: SCPage<SCTrack> = try await get("/tracks/\(trackId)/related", ["limit": "30"])
        return p.collection
    }

    // MARK: search

    func searchTracks(_ q: String, next: String?) async throws -> ([SCTrack], String?) {
        let p: SCPage<SCTrack> = try await get(next ?? "/search/tracks", next == nil ? ["q": q, "limit": "30"] : [:])
        return (p.collection, p.nextHref)
    }

    func searchUsers(_ q: String, next: String?) async throws -> ([SCUser], String?) {
        let p: SCPage<SCUser> = try await get(next ?? "/search/users", next == nil ? ["q": q, "limit": "30"] : [:])
        return (p.collection, p.nextHref)
    }

    func searchPlaylists(_ q: String, albums: Bool, next: String?) async throws -> ([SCPlaylist], String?) {
        let path = albums ? "/search/albums" : "/search/playlists_without_albums"
        let p: SCPage<SCPlaylist> = try await get(next ?? path, next == nil ? ["q": q, "limit": "30"] : [:])
        return (p.collection, p.nextHref)
    }

    // MARK: discovery

    func selections() async throws -> [SCSelection] {
        let p: SCPage<SCSelection> = try await get("/mixed-selections", ["limit": "20"])
        return p.collection
    }

    func charts(kind: String, genre: String, next: String?) async throws -> ([SCTrack], String?) {
        let p: SCPage<SCChartItem> = try await get(next ?? "/charts", next == nil ? ["kind": kind, "genre": genre, "limit": "50"] : [:])
        return (p.collection.compactMap { $0.track }, p.nextHref)
    }

    // MARK: playlists and users

    func playlist(_ p: SCPlaylist) async throws -> SCPlaylist {
        if p.isSystem, let urn = p.urn {
            return try await get("/system-playlists/\(urn)")
        }
        return try await get("/playlists/\(p.id.value)")
    }

    func user(_ id: Int) async throws -> SCUser { try await get("/users/\(id)") }

    func userTracks(_ id: Int, popular: Bool, next: String?) async throws -> ([SCTrack], String?) {
        let p: SCPage<SCTrack> = try await get(next ?? "/users/\(id)/\(popular ? "toptracks" : "tracks")", next == nil ? ["limit": "50"] : [:])
        return (p.collection, p.nextHref)
    }

    func userPlaylists(_ id: Int, albums: Bool, next: String?) async throws -> ([SCPlaylist], String?) {
        let p: SCPage<SCPlaylist> = try await get(next ?? "/users/\(id)/\(albums ? "albums" : "playlists_without_albums")", next == nil ? ["limit": "50"] : [:])
        return (p.collection, p.nextHref)
    }

    func userLikes(_ id: Int, next: String?) async throws -> ([SCTrack], String?) {
        let p: SCPage<SCLikeItem> = try await get(next ?? "/users/\(id)/track_likes", next == nil ? ["limit": "50"] : [:])
        return (p.collection.compactMap { $0.track }, p.nextHref)
    }

    // MARK: account

    func me() async throws -> SCUser { try await get("/me", auth: true) }

    func likedTrackIds() async throws -> [Int] {
        let p: SCPage<Int> = try await get("/me/track_likes/ids", ["limit": "5000"], auth: true)
        return p.collection
    }

    func followingIds() async throws -> [Int] {
        let p: SCPage<Int> = try await get("/me/followings/ids", ["limit": "5000"], auth: true)
        return p.collection
    }

    func setLike(trackId: Int, userId: Int, on: Bool) async throws {
        try await request(on ? "PUT" : "DELETE", "/users/\(userId)/track_likes/\(trackId)", auth: true)
    }

    func setFollow(userId: Int, on: Bool) async throws {
        try await request(on ? "POST" : "DELETE", "/me/followings/\(userId)", auth: true)
    }

    func feed(next: String?) async throws -> ([SCStreamItem], String?) {
        let p: SCPage<SCStreamItem> = try await get(next ?? "/stream", next == nil ? ["limit": "30"] : [:], auth: true)
        // Promoted items are ads in the feed: never shown.
        return (p.collection.filter { !($0.type ?? "").contains("promoted") }, p.nextHref)
    }

    func libraryPlaylists(next: String?) async throws -> ([SCPlaylist], String?) {
        let p: SCPage<SCLibraryItem> = try await get(next ?? "/me/library/all", next == nil ? ["limit": "50"] : [:], auth: true)
        return (p.collection.compactMap { $0.playlist ?? $0.systemPlaylist }, p.nextHref)
    }

    func history(next: String?) async throws -> ([SCTrack], String?) {
        let p: SCPage<SCHistoryItem> = try await get(next ?? "/me/play-history/tracks", next == nil ? ["limit": "50"] : [:], auth: true)
        return (p.collection.compactMap { $0.track }, p.nextHref)
    }
}

// MARK: regex helpers

func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

func allMatches(_ pattern: String, in s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
        Range(m.range, in: s).map { String(s[$0]) }
    }
}
