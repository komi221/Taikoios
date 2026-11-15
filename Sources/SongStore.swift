import Foundation
import SwiftUI

@MainActor
final class SongStore: ObservableObject {
    @Published var songs: [SongInfo] = []
    @Published var status = ""
    @Published var loading = false
    @Published var categoryColors: [Int: Color] = [:]
    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var downloadingIDs: Set<String> = []

    private var remote: [SongInfo] = []
    private var locals: [SongInfo] = []
    private var cachedSongsBase: URL?
    private let fm = FileManager.default

    var baseURL: URL {
        let s = (UserDefaults.standard.string(forKey: "baseURL") ?? kDefaultBase)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: s) ?? URL(string: kDefaultBase)!
    }
    private var docs: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var songsDir: URL { docs.appendingPathComponent("songs", isDirectory: true) }
    private var cacheKey: String {
        baseURL.absoluteString.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
    private var listFile: URL { docs.appendingPathComponent("songs_\(cacheKey).json") }
    private var localFile: URL { docs.appendingPathComponent("locals.json") }

    init() {
        if let saved = UserDefaults.standard.array(forKey: "taikoFavorites") as? [String] { favoriteIDs = Set(saved) }
        loadCached()
    }

    func key(for song: SongInfo) -> String {
        let scope = song.id < 0 ? "local" : baseURL.absoluteString
        return "\(scope)#\(song.id)"
    }
    func isFavorite(_ song: SongInfo) -> Bool { favoriteIDs.contains(key(for: song)) }
    func toggleFavorite(_ song: SongInfo) {
        let key = key(for: song)
        if favoriteIDs.contains(key) { favoriteIDs.remove(key) } else { favoriteIDs.insert(key) }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "taikoFavorites")
    }


    private func loadRemoteCache() {
        remote = []
        if let d = try? Data(contentsOf: listFile),
           let l = try? JSONDecoder().decode([Lossy<SongInfo>].self, from: d) { remote = l.compactMap { $0.value } }
    }

    /// 설정에서 서버를 바꿨을 때: 그 서버의 저장된 목록을 먼저 보여주고 새로 받아온다.
    func switchServer() {
        cachedSongsBase = nil
        status = ""
        loadRemoteCache()
        rebuild()
        Task { await refresh() }
    }

    private func loadCached() {
        loadRemoteCache()
        if let d = try? Data(contentsOf: localFile),
           let l = try? JSONDecoder().decode([SongInfo].self, from: d) { locals = l }
        rebuild()
    }

    private func rebuild() {
        let r = remote.sorted {
    let a = $0.category_id ?? 0
    let b = $1.category_id ?? 0

    if a != b { return a < b }

    let ao = $0.order ?? ""
    let bo = $1.order ?? ""

    if ao != bo { return ao < bo }

    return $0.id < $1.id
}
        songs = locals + r
        refreshDownloadedState()
    }

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw SimpleError("HTTP \(h.statusCode)") }
        return data
    }

    func loadCategories() async {
        guard let data = try? await fetch(baseURL.appendingPathComponent("api/categories")),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var map: [Int: Color] = [:]
        for c in arr {
            if let id = c["id"] as? Int, let skin = c["song_skin"] as? [String: Any],
               let hex = skin["background"] as? String, let col = Color(hex: hex) { map[id] = col }
        }
        categoryColors = map
    }

    func refresh() async {
        loading = true; defer { loading = false }
        Task { await loadCategories() }
        do {
            let data = try await fetch(baseURL.appendingPathComponent("api/songs"))
            let decoded = try JSONDecoder().decode([Lossy<SongInfo>].self, from: data)
            let list = decoded.compactMap { $0.value }
            let skipped = decoded.count - list.count
            try? data.write(to: listFile)
            remote = list
            cachedSongsBase = nil
            status = "곡 \(list.count)개 불러옴" + (skipped > 0 ? " · 데이터 오류 \(skipped)개 제외" : "")
        } catch {
            status = remote.isEmpty
                ? "서버 연결 실패 – 오른쪽 위 가져오기로 TJA+음원을 직접 넣어 주세요"
                : "서버 연결 실패 – 저장된 목록 사용 중"
        }
        rebuild()
    }

    // MARK: 다운로드

    private func songsBaseURL() async -> URL {
        if let c = cachedSongsBase { return c }
        var result = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString + "songs/" : baseURL.absoluteString + "/songs/"
        if let data = try? await fetch(baseURL.appendingPathComponent("api/config")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var s = obj["songs_baseurl"] as? String, !s.isEmpty {
            if !s.hasSuffix("/") { s += "/" }
            if let u = URL(string: s, relativeTo: baseURL)?.absoluteURL { result = u.absoluteString }
        }
        let u = URL(string: result)!
        cachedSongsBase = u
        return u
    }

    func files(for song: SongInfo) -> (dir: URL, tja: URL, audio: URL) {
    let dir = song.isLocal
        ? songsDir.appendingPathComponent("local/\(song.id)", isDirectory: true)
        : songsDir.appendingPathComponent("\(cacheKey)/\(song.id)", isDirectory: true)

    return (
        dir,
        dir.appendingPathComponent("main.tja"),
        dir.appendingPathComponent("main.\(song.audioExt)")
    )
}

    private func fileSize(_ url: URL) -> Int {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    func isDownloaded(_ song: SongInfo) -> Bool {
        let f = files(for: song)
        guard fm.fileExists(atPath: f.tja.path), fm.fileExists(atPath: f.audio.path) else { return false }
        return fileSize(f.tja) > 0 && fileSize(f.audio) > 0
    }

    func ensureDownloaded(_ song: SongInfo) async throws -> (tja: URL, audio: URL) {
        let f = files(for: song)
        if isDownloaded(song) { return (f.tja, f.audio) }
        if song.isLocal {
              throw SimpleError("가져온 곡 파일이 없어요. 다시 가져와 주세요")}
        try fm.createDirectory(at: f.dir, withIntermediateDirectories: true)
        let base = await songsBaseURL()
        let tjaTmp = f.dir.appendingPathComponent("main.tja.part")
        let audioTmp = f.dir.appendingPathComponent("main.\(song.audioExt.lowercased()).part")
        defer { try? fm.removeItem(at: tjaTmp); try? fm.removeItem(at: audioTmp) }
        for (name, temp) in [("main.tja", tjaTmp), ("main.\(song.audioExt.lowercased())", audioTmp)] {
            let url = base.appendingPathComponent(String(song.id)).appendingPathComponent(name)
            var request = URLRequest(url: url); request.timeoutInterval = 60
            let (tmp, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SimpleError("\(name) 받기 실패 (HTTP \(http.statusCode))")
            }
            guard fileSize(tmp) > 0 else { throw SimpleError("\(name) 파일이 비어 있어요") }
            try? fm.removeItem(at: temp)
            try fm.moveItem(at: tmp, to: temp)
        }
        // 두 파일 모두 받은 뒤에만 기존 파일을 교체해 반쪽 다운로드를 방지
        try? fm.removeItem(at: f.tja); try? fm.removeItem(at: f.audio)
        try fm.moveItem(at: tjaTmp, to: f.tja)
        try fm.moveItem(at: audioTmp, to: f.audio)
        refreshDownloadedState()
        return (f.tja, f.audio)
    }

    func download(_ song: SongInfo) async {
        let key = key(for: song)
        guard !downloadingIDs.contains(key), !isDownloaded(song) else { return }
        downloadingIDs.insert(key)
        defer { downloadingIDs.remove(key) }
        do {
            _ = try await ensureDownloaded(song)
            status = "다운로드 완료: \(song.displayTitle)"
        } catch {
            status = "다운로드 실패: \(song.displayTitle) · \(error.localizedDescription)"
        }
    }

    func exportFiles(for song: SongInfo) -> [URL] {
        guard isDownloaded(song) else { return [] }
        let f = files(for: song)
        return [f.tja, f.audio]
    }

    private func refreshDownloadedState() {
        downloadedIDs = Set(songs.filter { isDownloaded($0) }.map { key(for: $0) })
    }

    // MARK: 직접 가져오기

    func importLocal(urls: [URL]) {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let audioExts = ["ogg", "mp3", "wav", "m4a", "aac", "flac"]
        guard let tja = urls.first(where: { $0.pathExtension.lowercased() == "tja" }),
              let audio = urls.first(where: { audioExts.contains($0.pathExtension.lowercased()) }) else {
            status = "TJA 파일과 음원 파일을 함께 선택해 주세요"; return
        }
        do {
            let data = try Data(contentsOf: tja)
            let parsed = TJAParser.parse(TJAParser.decode(data))
            let id = -Int(Date().timeIntervalSince1970)
            let ext = audio.pathExtension.lowercased()
            let dir = songsDir.appendingPathComponent("local/\(id)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("main.tja"))
            try fm.copyItem(at: audio, to: dir.appendingPathComponent("main.\(ext)"))
            var courses: [String: CourseInfo?] = [:]
            for (k, c) in parsed.charts { courses[k] = CourseInfo(branch: false, stars: c.level) }
            let title = parsed.title.isEmpty ? tja.deletingPathExtension().lastPathComponent : parsed.title
            locals.insert(SongInfo(id: id, title: title, subtitle: parsed.subtitle, title_lang: nil,
                                   category: "가져온 곡", category_id: -1, courses: courses,
                                   music_type: ext, order: 0), at: 0)
            try JSONEncoder().encode(locals).write(to: localFile)
            status = "가져옴: \(title)"
            rebuild()
        } catch {
            status = "가져오기 실패: \(error.localizedDescription)"
        }
    }
}
