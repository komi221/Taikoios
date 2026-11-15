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
    private var cachedCandidates: [URL] = []
    private let fm = FileManager.default

    // 곡마다 UserDefaults 를 읽고 URL 을 다시 만들면 목록이 길 때 화면이 매번 멈칫한다 → 한 번만 계산해 둔다
    private var cachedBase: URL?
    private var cachedCacheKey: String?
    var baseURL: URL {
        if let c = cachedBase { return c }
        let s = (UserDefaults.standard.string(forKey: "baseURL") ?? kDefaultBase)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let u = URL(string: s) ?? URL(string: kDefaultBase)!
        cachedBase = u
        return u
    }
    private lazy var docs: URL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var songsDir: URL { docs.appendingPathComponent("songs", isDirectory: true) }
    private var cacheKey: String {
        if let c = cachedCacheKey { return c }
        let k = baseURL.absoluteString.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        cachedCacheKey = k
        return k
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
    func setFavorite(_ list: [SongInfo], on: Bool) {
        for s in list { if on { favoriteIDs.insert(key(for: s)) } else { favoriteIDs.remove(key(for: s)) } }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "taikoFavorites")
        status = on ? "즐겨찾기 \(list.count)곡 추가" : "즐겨찾기 \(list.count)곡 해제"
    }


    private func loadRemoteCache() {
        remote = []
        if let d = try? Data(contentsOf: listFile) { remote = SongInfo.parseList(d).songs }
    }

    /// 설정에서 서버를 바꿨을 때: 그 서버의 저장된 목록을 먼저 보여주고 새로 받아온다.
    func switchServer() {
        cachedBase = nil; cachedCacheKey = nil
        cachedCandidates = []
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
            if ($0.category_id ?? 0) != ($1.category_id ?? 0) { return ($0.category_id ?? 0) < ($1.category_id ?? 0) }
            if ($0.order ?? 0) != ($1.order ?? 0) { return ($0.order ?? 0) < ($1.order ?? 0) }
            let a = $0.displayTitle.lowercased(), b = $1.displayTitle.lowercased()
            return a != b ? a < b : $0.id < $1.id
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
            let parsed = SongInfo.parseList(data)
            if parsed.songs.isEmpty { throw SimpleError("곡 목록을 읽지 못했어요 (\(parsed.sample))") }
            try? data.write(to: listFile)
            remote = parsed.songs
            cachedCandidates = []
            status = "곡 \(parsed.songs.count)개 불러옴" + (parsed.skipped > 0 ? " · 데이터 오류 \(parsed.skipped)개 제외 (예: \(parsed.sample))" : "")
        } catch {
            let why = error.localizedDescription
            status = remote.isEmpty
                ? "서버 연결/읽기 실패: \(why) – 오른쪽 위 가져오기로 TJA+음원을 직접 넣어 주세요"
                : "서버 연결/읽기 실패(\(why)) – 저장된 목록 사용 중"
        }
        rebuild()
    }

    // MARK: 다운로드

    /// 곡 파일 주소 후보: api/config 의 songs_baseurl 먼저, 그다음 <서버>/songs/
    private func songsBaseCandidates() async -> [URL] {
        if !cachedCandidates.isEmpty { return cachedCandidates }
        var list: [URL] = []
        if let data = try? await fetch(baseURL.appendingPathComponent("api/config")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var s = obj["songs_baseurl"] as? String, !s.isEmpty {
            if !s.hasSuffix("/") { s += "/" }
            if let u = URL(string: s, relativeTo: baseURL)?.absoluteURL { list.append(u) }
        }
        let plain = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString + "songs/" : baseURL.absoluteString + "/songs/"
        if let u = URL(string: plain), !list.contains(u) { list.append(u) }
        cachedCandidates = list
        return list
    }

    private func safeName(_ s: String) -> String {
        String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") ? $0 : "_" })
    }

    func files(for song: SongInfo) -> (dir: URL, tja: URL, audio: URL) {
        // 가져온 곡(음수 id)은 서버와 무관, 서버 곡은 서버별 폴더 (서버끼리 id가 겹쳐도 안전)
        let dir = song.id < 0
            ? songsDir.appendingPathComponent("local/\(song.id)", isDirectory: true)
            : songsDir.appendingPathComponent("\(cacheKey)/\(safeName(song.serverID))", isDirectory: true)
        return (dir, dir.appendingPathComponent("main.tja"), dir.appendingPathComponent("main.\(song.audioExt.lowercased())"))
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    func isDownloaded(_ song: SongInfo) -> Bool {
        let f = files(for: song)
        guard fm.fileExists(atPath: f.dir.path) else { return false }
        guard fm.fileExists(atPath: f.tja.path), fm.fileExists(atPath: f.audio.path) else { return false }
        return fileSize(f.tja) > 0 && fileSize(f.audio) > 0
    }

    func ensureDownloaded(_ song: SongInfo) async throws -> (tja: URL, audio: URL) {
        let f = files(for: song)
        if isDownloaded(song) { return (f.tja, f.audio) }
        if song.id < 0 { throw SimpleError("가져온 곡 파일이 없어요. 다시 가져와 주세요") }
        try fm.createDirectory(at: f.dir, withIntermediateDirectories: true)
        let bases = await songsBaseCandidates()
        let tjaTmp = f.dir.appendingPathComponent("main.tja.part")
        let audioTmp = f.dir.appendingPathComponent("main.\(song.audioExt.lowercased()).part")
        defer { try? fm.removeItem(at: tjaTmp); try? fm.removeItem(at: audioTmp) }
        for (name, temp) in [("main.tja", tjaTmp), ("main.\(song.audioExt.lowercased())", audioTmp)] {
            var lastError: Error = SimpleError("\(name) 받기 실패")
            var ok = false
            for base in bases {   // 첫 주소가 안 되면 다음 후보 주소로 재시도
                let url = base.appendingPathComponent(song.serverID).appendingPathComponent(name)
                var request = URLRequest(url: url); request.timeoutInterval = 60
                do {
                    let (tmp, response) = try await URLSession.shared.download(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw SimpleError("\(name) 받기 실패 (HTTP \(http.statusCode))")
                    }
                    guard fileSize(tmp) > 0 else { throw SimpleError("\(name) 파일이 비어 있어요") }
                    try? fm.removeItem(at: temp)
                    try fm.moveItem(at: tmp, to: temp)
                    ok = true; break
                } catch { lastError = error }
            }
            if !ok { throw lastError }
        }
        // 두 파일 모두 받은 뒤에만 기존 파일을 교체해 반쪽 다운로드를 방지
        try? fm.removeItem(at: f.tja); try? fm.removeItem(at: f.audio)
        try fm.moveItem(at: tjaTmp, to: f.tja)
        try fm.moveItem(at: audioTmp, to: f.audio)
        downloadedIDs.insert(key(for: song))
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

    private func downloadQuiet(_ song: SongInfo) async -> Bool {
        let k = key(for: song)
        guard !downloadingIDs.contains(k) else { return false }
        downloadingIDs.insert(k)
        defer { downloadingIDs.remove(k) }
        do { _ = try await ensureDownloaded(song); return true } catch { return false }
    }

    // MARK: 다운로드 용량 확인

    /// 서버에 파일 크기만 물어본다 (HEAD → 안 되면 Range 0-0 의 Content-Range)
    nonisolated private func remoteSize(of url: URL) async -> Int64? {
        var head = URLRequest(url: url); head.httpMethod = "HEAD"; head.timeoutInterval = 15
        if let (_, resp) = try? await URLSession.shared.data(for: head), let h = resp as? HTTPURLResponse,
           (200...299).contains(h.statusCode) {
            if let v = h.value(forHTTPHeaderField: "Content-Length"), let n = Int64(v), n > 0 { return n }
            if h.expectedContentLength > 0 { return h.expectedContentLength }
        }
        var rng = URLRequest(url: url); rng.timeoutInterval = 15
        rng.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, resp) = try? await URLSession.shared.data(for: rng), let h = resp as? HTTPURLResponse,
           let cr = h.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/"),
           let n = Int64(cr[cr.index(after: slash)...]), n > 0 { return n }
        return nil
    }

    /// 한 곡(TJA + 음원) 크기. 둘 중 하나라도 모르면 nil
    nonisolated private func sizeOfSong(_ s: SongInfo, bases: [URL]) async -> Int64? {
        var sum: Int64 = 0
        for name in ["main.tja", "main.\(s.audioExt.lowercased())"] {
            var got: Int64?
            for base in bases {
                let url = base.appendingPathComponent(s.serverID).appendingPathComponent(name)
                if let n = await remoteSize(of: url) { got = n; break }
            }
            guard let g = got else { return nil }
            sum += g
        }
        return sum
    }

    /// 받을 곡들의 총 용량(바이트)과, 크기를 알아내지 못한 곡 수
    func estimateDownloadSize(_ list: [SongInfo]) async -> (bytes: Int64, unknown: Int) {
        let todo = list.filter { $0.id >= 0 && !isDownloaded($0) }
        let bases = await songsBaseCandidates()
        var total: Int64 = 0, unknown = 0
        var it = todo.makeIterator()
        await withTaskGroup(of: Int64?.self) { group in
            for _ in 0..<6 { if let s = it.next() { group.addTask { await self.sizeOfSong(s, bases: bases) } } }
            while let r = await group.next() {
                if let r { total += r } else { unknown += 1 }
                if let s = it.next() { group.addTask { await self.sizeOfSong(s, bases: bases) } }
            }
        }
        return (total, unknown)
    }

    /// 선택한 곡 일괄 다운로드 (동시에 3곡씩)
    func downloadMany(_ list: [SongInfo]) async {
        let todo = list.filter { $0.id >= 0 && !downloadedIDs.contains(key(for: $0)) }
        guard !todo.isEmpty else { status = "새로 받을 곡이 없어요"; return }
        var done = 0, failed = 0
        status = "다운로드 0/\(todo.count)"
        var it = todo.makeIterator()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 { if let s = it.next() { group.addTask { await self.downloadQuiet(s) } } }
            while let ok = await group.next() {
                done += 1; if !ok { failed += 1 }
                status = "다운로드 \(done)/\(todo.count)" + (failed > 0 ? " · 실패 \(failed)" : "")
                if let s = it.next() { group.addTask { await self.downloadQuiet(s) } }
            }
        }
        status = "다운로드 완료 \(todo.count - failed)곡" + (failed > 0 ? " · 실패 \(failed)곡" : "")
    }

    /// 선택한 곡의 다운로드 파일 삭제 (가져온 곡은 원본이 없어지므로 건드리지 않음)
    func deleteDownloads(_ list: [SongInfo]) {
        var n = 0, skipped = 0
        for s in list where downloadedIDs.contains(key(for: s)) || isDownloaded(s) {
            if s.id < 0 { skipped += 1; continue }
            try? fm.removeItem(at: files(for: s).dir)
            downloadedIDs.remove(key(for: s)); n += 1
        }
        status = "다운로드 \(n)곡 삭제" + (skipped > 0 ? " · 가져온 곡 \(skipped)곡은 유지" : "")
    }

    func exportFiles(for song: SongInfo) -> [URL] {
        guard isDownloaded(song) else { return [] }
        let f = files(for: song)
        return [f.tja, f.audio]
    }

    private func refreshDownloadedState() {
        downloadedIDs = Set(songs.filter { isDownloaded($0) }.map { key(for: $0) })
    }

    // MARK: 미리듣기용 음원

    /// 다운로드된 곡은 그 파일, 아니면 음원만 임시 캐시로 받아서 돌려준다.
    func previewAudioURL(_ song: SongInfo) async -> URL? {
        let f = files(for: song)
        if isDownloaded(song) { return f.audio }
        if song.id < 0 { return nil }
        let ext = song.audioExt.lowercased()
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("preview", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(atPath: dir.path), items.count > 40 {
            items.forEach { try? fm.removeItem(at: dir.appendingPathComponent($0)) }   // 캐시가 쌓이면 비움
        }
        let dest = dir.appendingPathComponent("\(cacheKey)_\(safeName(song.serverID)).\(ext)")
        if fileSize(dest) > 0 { return dest }
        for base in await songsBaseCandidates() {
            let url = base.appendingPathComponent(song.serverID).appendingPathComponent("main.\(ext)")
            var req = URLRequest(url: url); req.timeoutInterval = 30
            guard let (tmp, resp) = try? await URLSession.shared.download(for: req) else { continue }
            if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { continue }
            guard fileSize(tmp) > 0 else { continue }
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: tmp, to: dest)) != nil { return dest }
        }
        return nil
    }

    // MARK: 직접 가져오기

    private var importCounter = 0
    private let audioExts = ["ogg", "mp3", "wav", "m4a", "aac", "flac"]

    private func tjaWaveName(_ data: Data) -> String? {
        for raw in TJAParser.decode(data).components(separatedBy: .newlines).prefix(80) {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.uppercased().hasPrefix("WAVE:") {
                let v = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// TJA 한 곡 + 음원 한 개를 앱 안으로 복사해 목록에 추가
    private func importPair(tja: URL, audio: URL) throws -> String {
        let data = try Data(contentsOf: tja)
        let parsed = TJAParser.parse(TJAParser.decode(data))
        if parsed.charts.isEmpty { throw SimpleError("\(tja.lastPathComponent): 악보(#START)를 찾지 못했어요") }
        importCounter += 1
        let id = -(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000_000) - importCounter
        let ext = audio.pathExtension.lowercased()
        let dir = songsDir.appendingPathComponent("local/\(id)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("main.tja"))
        let dest = dir.appendingPathComponent("main.\(ext)")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: audio, to: dest)
        var courses: [String: CourseInfo?] = [:]
        for (k, c) in parsed.charts { courses[k] = CourseInfo(branch: false, stars: c.level) }
        let title = parsed.title.isEmpty ? tja.deletingPathExtension().lastPathComponent : parsed.title
        locals.insert(SongInfo(id: id, title: title, subtitle: parsed.subtitle, title_lang: nil,
                               category: "가져온 곡", category_id: -1, courses: courses,
                               music_type: ext, order: 0), at: 0)
        return title
    }

    /// 파일 묶음에서 TJA 와 음원을 짝지어 가져온다 (TJA 의 WAVE: 이름 → 같은 이름 → 하나뿐이면 그것)
    private func importGroup(_ files: [URL]) -> (ok: [String], errors: [String]) {
        let tjas = files.filter { $0.pathExtension.lowercased() == "tja" }
        let audios = files.filter { audioExts.contains($0.pathExtension.lowercased()) }
        var ok: [String] = [], errors: [String] = []
        var used = Set<URL>()
        for tja in tjas {
            let data = try? Data(contentsOf: tja)
            var match: URL?
            if let d = data, let wave = tjaWaveName(d) {
                let w = (wave as NSString).lastPathComponent.lowercased()
                match = audios.first { $0.lastPathComponent.lowercased() == w }
            }
            if match == nil {
                let base = tja.deletingPathExtension().lastPathComponent.lowercased()
                match = audios.first { $0.deletingPathExtension().lastPathComponent.lowercased() == base && !used.contains($0) }
            }
            if match == nil, tjas.count == 1 { match = audios.first }
            if match == nil, let only = audios.filter({ !used.contains($0) }).first, audios.count == tjas.count { match = only }
            guard let audio = match else { errors.append("\(tja.lastPathComponent): 짝이 되는 음원이 없어요"); continue }
            used.insert(audio)
            do { ok.append(try importPair(tja: tja, audio: audio)) }
            catch { errors.append("\(tja.lastPathComponent): \(error.localizedDescription)") }
        }
        return (ok, errors)
    }

    private func finishImport(ok: [String], errors: [String], received: [URL]) -> String {
        if !ok.isEmpty {
            do { try JSONEncoder().encode(locals).write(to: localFile, options: .atomic) }
            catch { errors_append(error) }
            rebuild()
        }
        var msg = ""
        if !ok.isEmpty { msg += "가져옴 \(ok.count)곡: " + ok.prefix(5).joined(separator: ", ") + (ok.count > 5 ? " 외" : "") }
        if !errors.isEmpty { msg += (msg.isEmpty ? "" : "\n") + "실패:\n" + errors.prefix(5).joined(separator: "\n") }
        if ok.isEmpty && errors.isEmpty {
            let names = received.prefix(8).map { $0.lastPathComponent }.joined(separator: ", ")
            msg = "TJA 파일과 음원 파일(ogg/mp3/wav…)을 함께 선택해 주세요.\n받은 파일 \(received.count)개: \(names.isEmpty ? "없음" : names)"
        }
        status = msg.replacingOccurrences(of: "\n", with: " ")
        return msg
    }
    private func errors_append(_ e: Error) { status = "목록 저장 실패: \(e.localizedDescription)" }

    /// 파일 선택기로 고른 파일들 가져오기
    @discardableResult
    func importLocal(urls: [URL]) -> String {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let r = importGroup(urls)
        return finishImport(ok: r.ok, errors: r.errors, received: urls)
    }

    /// 폴더 안의 모든 곡 폴더(TJA + 음원)를 한 번에 가져오기
    @discardableResult
    func importFolder(_ folder: URL) -> String {
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        var all: [URL] = []
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in en { all.append(u) }
        }
        var okList: [String] = [], errs: [String] = []
        let byDir = Dictionary(grouping: all) { $0.deletingLastPathComponent().path }
        for (_, files) in byDir {
            guard files.contains(where: { $0.pathExtension.lowercased() == "tja" }) else { continue }
            let r = importGroup(files)
            okList += r.ok; errs += r.errors
        }
        return finishImport(ok: okList, errors: errs, received: all)
    }
}
