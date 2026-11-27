import Foundation

/// Offline copies. An HLS stream is saved as one file: the init segment followed by every media
/// segment, which for fragmented MP4 (SoundCloud's AAC) is itself a playable .m4a, and for MP3
/// segments a plain .mp3.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    @Published private(set) var items: [SCTrack] = []
    @Published private(set) var ids: Set<Int> = []
    @Published private(set) var progress: [Int: Double] = [:]
    @Published var lastError: String?

    private let dir: URL
    private var pending: [SCTrack] = []
    private var active = 0
    private let maxActive = 2

    private init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        loadIndex()
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let list = (try? dec.decode([SCTrack].self, from: data)) ?? []
        items = list.filter { file(for: $0.id) != nil }
        ids = Set(items.map { $0.id })
    }

    private func saveIndex() {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? enc.encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func file(for id: Int) -> URL? {
        for ext in ["m4a", "mp3"] {
            let u = dir.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func localURL(for id: Int) -> URL? { ids.contains(id) ? file(for: id) : nil }

    func isDownloading(_ id: Int) -> Bool { progress[id] != nil }

    var totalBytes: Int64 {
        items.reduce(0) { sum, t in
            guard let u = file(for: t.id),
                  let size = try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber else { return sum }
            return sum + size.int64Value
        }
    }

    func download(_ tracks: [SCTrack]) {
        for t in tracks where !t.isStub && !ids.contains(t.id) && progress[t.id] == nil {
            progress[t.id] = 0
            pending.append(t)
        }
        pump()
    }

    func remove(_ t: SCTrack) {
        if let u = file(for: t.id) { try? FileManager.default.removeItem(at: u) }
        items.removeAll { $0.id == t.id }
        ids.remove(t.id)
        saveIndex()
    }

    func removeAll() {
        for t in items { if let u = file(for: t.id) { try? FileManager.default.removeItem(at: u) } }
        items = []
        ids = []
        saveIndex()
    }

    func cancelPending() {
        for t in pending { progress[t.id] = nil }
        pending = []
    }

    private func pump() {
        while active < maxActive, !pending.isEmpty {
            let t = pending.removeFirst()
            active += 1
            let dir = self.dir
            Task {
                do {
                    _ = try await HLSDownloader.save(track: t, into: dir) { p in
                        Task { @MainActor in
                            if Downloads.shared.progress[t.id] != nil { Downloads.shared.progress[t.id] = p }
                        }
                    }
                    items.insert(t, at: 0)
                    ids.insert(t.id)
                    saveIndex()
                } catch {
                    lastError = "\(t.title ?? "Трек"): \(error.localizedDescription)"
                }
                progress[t.id] = nil
                active -= 1
                pump()
            }
        }
    }
}

enum HLSDownloader {
    static func save(track: SCTrack, into dir: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let streamURL = try await SCClient.shared.streamURL(for: track)
        let session = URLSession.shared
        let tmp = dir.appendingPathComponent("\(track.id).part")
        try? FileManager.default.removeItem(at: tmp)

        let (first, _) = try await session.data(from: streamURL)
        var ext = "mp3"
        if let text = String(data: first, encoding: .utf8), text.hasPrefix("#EXTM3U") {
            var playlistURL = streamURL
            var body = text
            if body.contains("#EXT-X-STREAM-INF") {
                // Master playlist: take its first variant.
                guard let line = lines(body).first(where: { !$0.hasPrefix("#") }),
                      let variant = URL(string: line, relativeTo: streamURL)?.absoluteURL else { throw SCError.noStream }
                playlistURL = variant
                let (d, _) = try await session.data(from: variant)
                body = String(decoding: d, as: UTF8.self)
            }
            if body.contains("#EXT-X-KEY") && !body.contains("METHOD=NONE") { throw SCError.encrypted }

            var initURL: URL?
            var segments: [URL] = []
            for line in lines(body) {
                if line.hasPrefix("#EXT-X-MAP:") {
                    if let r = line.range(of: "URI=\"") {
                        let rest = line[r.upperBound...]
                        if let end = rest.firstIndex(of: "\"") {
                            initURL = URL(string: String(rest[..<end]), relativeTo: playlistURL)?.absoluteURL
                        }
                    }
                } else if !line.hasPrefix("#"), let u = URL(string: line, relativeTo: playlistURL)?.absoluteURL {
                    segments.append(u)
                }
            }
            guard !segments.isEmpty else { throw SCError.noStream }

            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                if let initURL {
                    let (d, _) = try await session.data(from: initURL)
                    handle.write(d)
                }
                for (n, s) in segments.enumerated() {
                    try Task.checkCancellation()
                    let (d, _) = try await session.data(from: s)
                    handle.write(d)
                    progress(Double(n + 1) / Double(segments.count))
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
            ext = initURL != nil ? "m4a" : "mp3"
        } else {
            try first.write(to: tmp)
        }

        let final = dir.appendingPathComponent("\(track.id).\(ext)")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    private static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Recently played, kept on the device (also without an account).
@MainActor
final class History: ObservableObject {
    static let shared = History()

    @Published private(set) var tracks: [SCTrack] = []
    private let key = "history.tracks"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        tracks = (try? dec.decode([SCTrack].self, from: data)) ?? []
    }

    func add(_ t: SCTrack) {
        tracks.removeAll { $0.id == t.id }
        tracks.insert(t, at: 0)
        if tracks.count > 200 { tracks.removeLast(tracks.count - 200) }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? enc.encode(tracks) { UserDefaults.standard.set(data, forKey: key) }
    }

    func clear() {
        tracks = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// What was opened from search, newest first, plus the typed queries.
enum RecentItem: Codable, Hashable, Identifiable {
    case track(SCTrack)
    case user(SCUser)
    case playlist(SCPlaylist)

    var id: String {
        switch self {
        case .track(let t): return "t\(t.id)"
        case .user(let u): return "u\(u.id)"
        case .playlist(let p): return "p\(p.id.value)"
        }
    }
}

/// Recent searches.
@MainActor
final class SearchHistory: ObservableObject {
    static let shared = SearchHistory()
    @Published private(set) var queries: [String] = UserDefaults.standard.stringArray(forKey: "search.recent") ?? []
    @Published private(set) var items: [RecentItem] = []
    private let itemsKey = "search.recentItems"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: itemsKey) else { return }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        items = (try? dec.decode([RecentItem].self, from: data)) ?? []
    }

    func add(_ q: String) {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(s) == .orderedSame }
        queries.insert(s, at: 0)
        if queries.count > 20 { queries.removeLast(queries.count - 20) }
        UserDefaults.standard.set(queries, forKey: "search.recent")
    }

    func add(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > 30 { items.removeLast(items.count - 30) }
        saveItems()
    }

    func remove(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        saveItems()
    }

    func clear() {
        queries = []
        items = []
        UserDefaults.standard.removeObject(forKey: "search.recent")
        UserDefaults.standard.removeObject(forKey: itemsKey)
    }

    private func saveItems() {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? enc.encode(items) { UserDefaults.standard.set(data, forKey: itemsKey) }
    }
}
