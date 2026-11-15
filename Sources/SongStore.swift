
import Foundation
import SwiftUI

@MainActor
final class SongStore: ObservableObject {

    // MARK: - Published State

    @Published var songs: [SongInfo] = []
    @Published var status = ""
    @Published var loading = false
    @Published var categoryColors: [Int: Color] = [:]

    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var downloadingIDs: Set<String> = []

    // MARK: - Internal State

    private var remote: [SongInfo] = []
    private var locals: [SongInfo] = []
    private var cachedSongsBase: URL?

    private let fm = FileManager.default

    // MARK: - Paths and Server

    var baseURL: URL {
        let s = (
            UserDefaults.standard.string(forKey: "baseURL")
            ?? kDefaultBase
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return URL(string: s) ?? URL(string: kDefaultBase)!
    }

    private var docs: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var songsDir: URL {
        docs.appendingPathComponent("songs", isDirectory: true)
    }

    private var cacheKey: String {
        baseURL.absoluteString
            .map {
                $0.isLetter || $0.isNumber
                    ? String($0)
                    : "_"
            }
            .joined()
    }

    private var listFile: URL {
        docs.appendingPathComponent("songs_\(cacheKey).json")
    }

    private var localFile: URL {
        docs.appendingPathComponent("locals.json")
    }

    // MARK: - Initialization

    init() {
        if let saved = UserDefaults.standard.array(
            forKey: "taikoFavorites"
        ) as? [String] {
            favoriteIDs = Set(saved)
        }

        loadCached()
    }

    // MARK: - Song Identity

    func key(for song: SongInfo) -> String {
        let scope = song.isLocal
            ? "local"
            : baseURL.absoluteString

        return "\(scope)#\(song.id)"
    }

    func isFavorite(_ song: SongInfo) -> Bool {
        favoriteIDs.contains(key(for: song))
    }

    func toggleFavorite(_ song: SongInfo) {
        let songKey = key(for: song)

        if favoriteIDs.contains(songKey) {
            favoriteIDs.remove(songKey)
        } else {
            favoriteIDs.insert(songKey)
        }

        UserDefaults.standard.set(
            Array(favoriteIDs),
            forKey: "taikoFavorites"
        )
    }

    // MARK: - Cache

    private func loadRemoteCache() {
        remote = []

        guard
            let data = try? Data(contentsOf: listFile),
            let list = try? JSONDecoder().decode(
                [Lossy<SongInfo>].self,
                from: data
            )
        else {
            return
        }

        remote = list.compactMap { $0.value }
    }

    private func loadCached() {
        loadRemoteCache()

        if let data = try? Data(contentsOf: localFile),
           let list = try? JSONDecoder().decode(
                [SongInfo].self,
                from: data
           ) {
            locals = list
        }

        rebuild()
    }

    func switchServer() {
        cachedSongsBase = nil
        status = ""

        loadRemoteCache()
        rebuild()

        Task {
            await refresh()
        }
    }

    // MARK: - Song List

    private func rebuild() {
        let sorted = remote.sorted {
            let a = $0.category_id ?? 0
            let b = $1.category_id ?? 0

            if a != b {
                return a < b
            }

            let ao = $0.order ?? ""
            let bo = $1.order ?? ""

            if ao != bo {
                return ao < bo
            }

            return $0.id < $1.id
        }

        songs = locals + sorted
        refreshDownloadedState()
    }

    // MARK: - Network

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SimpleError("HTTP \(http.statusCode)")
        }

        return data
    }

    // MARK: - Categories

    func loadCategories() async {
        guard
            let data = try? await fetch(
                baseURL.appendingPathComponent("api/categories")
            ),
            let array = try? JSONSerialization.jsonObject(
                with: data
            ) as? [[String: Any]]
        else {
            return
        }

        var map: [Int: Color] = [:]

        for category in array {
            if let id = category["id"] as? Int,
               let skin = category["song_skin"] as? [String: Any],
               let hex = skin["background"] as? String,
               let color = Color(hex: hex) {
                map[id] = color
            }
        }

        categoryColors = map
    }

    // MARK: - Refresh Song List

    func refresh() async {
        loading = true
        defer { loading = false }

        Task {
            await loadCategories()
        }

        do {
            let data = try await fetch(
                baseURL.appendingPathComponent("api/songs")
            )

            let decoded = try JSONDecoder().decode(
                [Lossy<SongInfo>].self,
                from: data
            )

            let list = decoded.compactMap { $0.value }
            let skipped = decoded.count - list.count

            try? data.write(to: listFile)

            remote = list
            cachedSongsBase = nil

            status = "곡 \(list.count)개 불러옴"

            if skipped > 0 {
                status += " · 데이터 오류 \(skipped)개 제외"
            }

        } catch {
            status = remote.isEmpty
                ? "서버 연결 실패 – 서버 주소와 API 응답을 확인해 주세요"
                : "서버 연결 실패 – 저장된 목록 사용 중"
        }

        rebuild()
    }

    // MARK: - Download Base URL

    private func songsBaseURL() async -> URL {
        if let cached = cachedSongsBase {
            return cached
        }

        var result = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString + "songs/"
            : baseURL.absoluteString + "/songs/"

        if let data = try? await fetch(
            baseURL.appendingPathComponent("api/config")
        ),
        let object = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
        var value = object["songs_baseurl"] as? String,
        !value.isEmpty {

            if !value.hasSuffix("/") {
                value += "/"
            }

            if let url = URL(
                string: value,
                relativeTo: baseURL
            )?.absoluteURL {
                result = url.absoluteString
            }
        }

        let url = URL(string: result)!
        cachedSongsBase = url

        return url
    }

    // MARK: - Song File Paths

    func files(
        for song: SongInfo
    ) -> (dir: URL, tja: URL, audio: URL) {

        let dir: URL

        if song.isLocal {
            dir = songsDir.appendingPathComponent(
                "local/\(song.id)",
                isDirectory: true
            )
        } else {
            dir = songsDir.appendingPathComponent(
                "\(cacheKey)/\(song.id)",
                isDirectory: true
            )
        }

        return (
            dir,
            dir.appendingPathComponent("main.tja"),
            dir.appendingPathComponent("main.\(song.audioExt)")
        )
    }

    // MARK: - File Validation

    private func fileSize(_ url: URL) -> Int {
        guard
            let attributes = try? fm.attributesOfItem(
                atPath: url.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return size.intValue
    }

    func isDownloaded(_ song: SongInfo) -> Bool {
        let files = files(for: song)

        guard
            fm.fileExists(atPath: files.tja.path),
            fm.fileExists(atPath: files.audio.path)
        else {
            return false
        }

        return fileSize(files.tja) > 0
            && fileSize(files.audio) > 0
    }

    // MARK: - Ensure Downloaded

    func ensureDownloaded(
        _ song: SongInfo
    ) async throws -> (tja: URL, audio: URL) {

        let files = files(for: song)

        if isDownloaded(song) {
            return (files.tja, files.audio)
        }

        if song.isLocal {
            throw SimpleError(
                "가져온 곡 파일이 없어요. 다시 가져와 주세요"
            )
        }

        try fm.createDirectory(
            at: files.dir,
            withIntermediateDirectories: true
        )

        let base = await songsBaseURL()

        let tjaTemp = files.dir.appendingPathComponent(
            "main.tja.part"
        )

        let audioName = "main.\(song.audioExt.lowercased())"

        let audioTemp = files.dir.appendingPathComponent(
            audioName + ".part"
        )

        defer {
            try? fm.removeItem(at: tjaTemp)
            try? fm.removeItem(at: audioTemp)
        }

        let downloadItems: [(String, URL)] = [
            ("main.tja", tjaTemp),
            (audioName, audioTemp)
        ]

        for (name, tempURL) in downloadItems {
            let url = base
                .appendingPathComponent(song.id)
                .appendingPathComponent(name)

            var request = URLRequest(url: url)
            request.timeoutInterval = 60

            let (temporaryFile, response) =
                try await URLSession.shared.download(
                    for: request
                )

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw SimpleError(
                    "\(name) 받기 실패 (HTTP \(http.statusCode))"
                )
            }

            guard fileSize(temporaryFile) > 0 else {
                throw SimpleError(
                    "\(name) 파일이 비어 있어요"
                )
            }

            try? fm.removeItem(at: tempURL)

            try fm.moveItem(
                at: temporaryFile,
                to: tempURL
            )
        }

        // 두 파일을 모두 받은 뒤 기존 파일 교체

        try? fm.removeItem(at: files.tja)
        try? fm.removeItem(at: files.audio)

        try fm.moveItem(
            at: tjaTemp,
            to: files.tja
        )

        try fm.moveItem(
            at: audioTemp,
            to: files.audio
        )

        refreshDownloadedState()

        return (files.tja, files.audio)
    }

    // MARK: - Download Song

    func download(_ song: SongInfo) async {
        let songKey = key(for: song)

        guard
            !downloadingIDs.contains(songKey),
            !isDownloaded(song)
        else {
            return
        }

        downloadingIDs.insert(songKey)
        defer {
            downloadingIDs.remove(songKey)
        }

        do {
            _ = try await ensureDownloaded(song)

            status = "다운로드 완료: \(song.displayTitle)"

        } catch {
            status = "다운로드 실패: \(song.displayTitle) · \(error.localizedDescription)"
        }

        refreshDownloadedState()
    }

    // MARK: - Export

    func exportFiles(for song: SongInfo) -> [URL] {
        guard isDownloaded(song) else {
            return []
        }

        let files = files(for: song)

        return [
            files.tja,
            files.audio
        ]
    }

    // MARK: - Download State

    private func refreshDownloadedState() {
        downloadedIDs = Set(
            songs
                .filter { isDownloaded($0) }
                .map { key(for: $0) }
        )
    }

    // MARK: - Import Local Song

    func importLocal(urls: [URL]) {
        let scoped = urls.filter {
            $0.startAccessingSecurityScopedResource()
        }

        defer {
            scoped.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
        }

        let audioExtensions = [
            "ogg", "mp3", "wav",
            "m4a", "aac", "flac"
        ]

        guard
            let tja = urls.first(where: {
                $0.pathExtension.lowercased() == "tja"
            }),
            let audio = urls.first(where: {
                audioExtensions.contains(
                    $0.pathExtension.lowercased()
                )
            })
        else {
            status = "TJA 파일과 음원 파일을 함께 선택해 주세요"
            return
        }

        do {
            let data = try Data(contentsOf: tja)

            let parsed = TJAParser.parse(
                TJAParser.decode(data)
            )

            // 로컬 곡도 문자열 ID 사용
            let id = "local-\(UUID().uuidString)"

            let ext = audio.pathExtension.lowercased()

            let dir = songsDir.appendingPathComponent(
                "local/\(id)",
                isDirectory: true
            )

            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )

            try data.write(
                to: dir.appendingPathComponent("main.tja")
            )

            try fm.copyItem(
                at: audio,
                to: dir.appendingPathComponent("main.\(ext)")
            )

            var courses: [String: CourseInfo?] = [:]

            for (key, chart) in parsed.charts {
                courses[key] = CourseInfo(
                    branch: false,
                    stars: chart.level
                )
            }

            let title = parsed.title.isEmpty
                ? tja.deletingPathExtension().lastPathComponent
                : parsed.title

            let song = SongInfo(
                id: id,
                title: title,
                subtitle: parsed.subtitle,
                title_lang: nil,
                category: "가져온 곡",
                category_id: -1,
                courses: courses,
                music_type: ext,
                order: "0"
            )

            locals.insert(song, at: 0)

            try JSONEncoder()
                .encode(locals)
                .write(to: localFile)

            status = "가져옴: \(title)"

            rebuild()

        } catch {
            status = "가져오기 실패: \(error.localizedDescription)"
        }
    }
}
