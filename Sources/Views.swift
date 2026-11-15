import SwiftUI
import SpriteKit
import AVFoundation
import UniformTypeIdentifiers
import UIKit

@main
struct TaikoApp: App {
    init() { Fonts.register() }
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: 곡 목록

struct PlayTarget: Identifiable {
    let song: SongInfo
    let course: String
    var id: String { "\(song.id)-\(course)" }
}

struct SongListView: View {
    @StateObject private var store = SongStore()
    @AppStorage("baseURL") private var baseURL = kDefaultBase
    @State private var query = ""
    @State private var dialogSong: SongInfo?
    @State private var play: PlayTarget?
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var listFilter = "전체"
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @ObservedObject private var scores = ScoreStore.shared

    private func scoreKey(_ s: SongInfo) -> String { "\(store.baseURL.absoluteString)#\(s.id)" }
    private func crownColor(_ c: String) -> Color { c == "gold" ? (Color(hex: "#ffd43a") ?? .yellow) : Color(white: 0.82) }

    private struct RecentRow: Identifiable {
        let song: SongInfo
        let course: String
        var id: String { "\(song.id)|\(course)" }
    }
    private var recentRows: [RecentRow] {
        let base = store.baseURL.absoluteString
        var out: [RecentRow] = []
        for r in scores.recents where r.key.hasPrefix(base + "#") {
            if let s = store.songs.first(where: { $0.id == r.songID }), s.availableCourses.contains(where: { $0.name == r.course }) {
                out.append(RecentRow(song: s, course: r.course))
            }
            if out.count >= 5 { break }
        }
        return out
    }

    /// 곡별 난이도 최고 기록: 왕관(풀콤보=금, 클리어=은) · 최고점 · 최대 콤보
    @ViewBuilder private func scoreSummary(_ s: SongInfo, only: String? = nil) -> some View {
        let best = scores.best(scoreKey(s))
        let rows: [(String, ScoreEntry)] = s.availableCourses.compactMap { c in
            if let only = only, only != c.name { return nil }
            return best[c.name].map { (c.name, $0) }
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 4) {
                        if !row.1.crown.isEmpty {
                            Image(systemName: "crown.fill").foregroundColor(crownColor(row.1.crown)).font(.caption2)
                        }
                        Text("\(courseLabel(row.0))  \(row.1.points)점 · 최대 \(row.1.maxCombo)콤보")
                            .font(.caption2).foregroundColor(.white.opacity(0.9))
                    }
                }
            }
        }
    }

    private var filtered: [SongInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.songs.filter { song in
            let matchesQuery = q.isEmpty || song.title.lowercased().contains(q)
                || song.displayTitle.lowercased().contains(q)
                || (song.title_lang?.ja ?? "").lowercased().contains(q)
            let key = store.key(for: song)
            let matchesFilter = listFilter == "전체"
                || (listFilter == "다운로드" && store.downloadedIDs.contains(key))
                || (listFilter == "즐겨찾기" && store.favoriteIDs.contains(key))
            return matchesQuery && matchesFilter
        }
    }

    private var groups: [SongGroup] {
        var order: [String] = []
        var dict: [String: [SongInfo]] = [:]
        for s in filtered {
            let c = s.category ?? "기타"
            if dict[c] == nil { order.append(c) }
            dict[c, default: []].append(s)
        }
        return order.map { SongGroup(name: $0, songs: dict[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("곡 필터", selection: $listFilter) {
                        Text("전체").tag("전체")
                        Text("다운로드").tag("다운로드")
                        Text("즐겨찾기").tag("즐겨찾기")
                    }.pickerStyle(.segmented)
                }
                if !store.status.isEmpty {
                    Text(store.status).font(.footnote).foregroundStyle(.secondary)
                }
                if listFilter == "전체" && query.trimmingCharacters(in: .whitespaces).isEmpty && !recentRows.isEmpty {
                    Section {
                        ForEach(recentRows) { row in
                            Button { play = PlayTarget(song: row.song, course: row.course) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.song.displayTitle).font(.custom(Fonts.kozuka, size: 17)).foregroundColor(.white)
                                    scoreSummary(row.song, only: row.course)
                                    if scores.get(scoreKey(row.song), row.course) == nil {
                                        Text("\(courseLabel(row.course)) · 기록 없음").font(.caption2).foregroundColor(.white.opacity(0.7))
                                    }
                                }
                            }
                            .listRowBackground(Color(white: 0.18))
                        }
                    } header: {
                        Text("최근 플레이").font(.custom(Fonts.tnt, size: 18)).foregroundColor(.white)
                    }
                }
                ForEach(groups) { g in
                    Section {
                        ForEach(g.songs) { s in
                            HStack(spacing: 10) {
                                Button { dialogSong = s } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(s.displayTitle).font(.custom(Fonts.kozuka, size: 19)).foregroundColor(.white)
                                            if store.isDownloaded(s) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption) }
                                        }
                                        if let sub = s.subtitle, !sub.isEmpty {
                                            Text(sub).font(.custom(Fonts.kozuka, size: 12)).foregroundColor(.white.opacity(0.8))
                                        }
                                        Text(s.availableCourses.map { "\(courseLabel($0.name))★\($0.stars)" }.joined(separator: "  "))
                                            .font(.caption2).foregroundColor(.yellow)
                                        scoreSummary(s)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { store.toggleFavorite(s) } label: {
                                    Image(systemName: store.isFavorite(s) ? "star.fill" : "star")
                                        .foregroundStyle(store.isFavorite(s) ? .yellow : .white.opacity(0.8))
                                }.buttonStyle(.borderless).accessibilityLabel("즐겨찾기")
                                if store.isDownloaded(s) {
                                    Button {
                                        shareURLs = store.exportFiles(for: s); showShare = !shareURLs.isEmpty
                                    } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(.white) }
                                    .buttonStyle(.borderless).accessibilityLabel("곡 내보내기")
                                } else {
                                    Button { Task { await store.download(s) } } label: {
                                        if store.downloadingIDs.contains(store.key(for: s)) { ProgressView() }
                                        else { Image(systemName: "arrow.down.circle").foregroundStyle(.white) }
                                    }
                                    .buttonStyle(.borderless).disabled(store.downloadingIDs.contains(store.key(for: s)) || s.id < 0)
                                    .accessibilityLabel("곡 다운로드")
                                }
                            }
                            .listRowBackground(store.categoryColors[s.category_id ?? -99]?.opacity(0.9) ?? Color(white: 0.15))
                        }
                    } header: {
                        Text(g.name).font(.custom(Fonts.tnt, size: 18)).foregroundColor(.white)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PatternBackground())
            .searchable(text: $query)
            .navigationTitle("太鼓ウェブ")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if store.loading { ProgressView() }
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .task { await store.refresh() }
        }
        .onChange(of: baseURL) { _ in store.switchServer() }
        .onAppear {
            Bgm.shared.play("bgm_songsel")
            Sfx.shared.preload(["se_don", "se_gameclear", "se_gamefail", "v_results"])
        }
        .onChange(of: play?.id) { id in
            if id == nil { Bgm.shared.play("bgm_songsel") } else { Bgm.shared.stop() }
        }
        .confirmationDialog(dialogSong?.displayTitle ?? "", isPresented: Binding(
            get: { dialogSong != nil }, set: { if !$0 { dialogSong = nil } }), titleVisibility: .visible,
            presenting: dialogSong) { song in
            ForEach(song.availableCourses) { c in
                Button("\(courseLabel(c.name))  ★\(c.stars)") { play = PlayTarget(song: song, course: c.name) }
            }
        }
        .fullScreenCover(item: $play) { t in GameView(store: store, song: t.song, course: t.course) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showShare) { ActivityShareSheet(items: shareURLs) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { store.importLocal(urls: urls) }
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 원본 bg-pattern-1.png 타일 배경
struct PatternBackground: View {
    var body: some View {
        ZStack {
            Color(hex: "#ff5a2b") ?? .orange
            if let img = Gfx.image("bg-pattern-1") {
                Image(uiImage: img).resizable(resizingMode: .tile).opacity(0.5)
            }
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
    }
}

// MARK: 설정

struct SettingsView: View {
    @AppStorage("baseURL") private var baseURL = kDefaultBase
    @AppStorage("serversJSON") private var serversJSON = "[\"https://cjdgrevival.com\"]"
    @AppStorage("calMs") private var calMs = 0.0
    @AppStorage("speedScale") private var speedScale = 1.0
    @AppStorage("autoLatency") private var autoLatency = true
    @AppStorage("fps120") private var fps120 = false
    @Environment(\.dismiss) private var dismiss
    @State private var newServer = ""

    private var servers: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(serversJSON.utf8))) ?? [kDefaultBase]
    }

    private func save(_ list: [String]) {
        if let d = try? JSONEncoder().encode(list), let s = String(data: d, encoding: .utf8) { serversJSON = s }
    }

    private func normalize(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains("://") { t = "https://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        return URL(string: t) != nil ? t : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("곡 서버 (탭해서 선택, 밀어서 삭제)") {
                    ForEach(servers, id: \.self) { s in
                        Button { baseURL = s } label: {
                            HStack {
                                Text(s).foregroundColor(.primary)
                                Spacer()
                                if s == baseURL { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                    }
                    .onDelete { idx in
                        var l = servers
                        l.remove(atOffsets: idx)
                        if l.isEmpty { l = [kDefaultBase] }
                        save(l)
                        if !l.contains(baseURL) { baseURL = l[0] }
                    }
                    HStack {
                        TextField("서버 주소 추가 (https://...)", text: $newServer)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("추가") {
                            if let u = normalize(newServer) {
                                if !servers.contains(u) { save(servers + [u]) }
                                baseURL = u
                                newServer = ""
                            }
                        }
                    }
                }
                Section("판정 보정: \(Int(calMs)) ms") {
                    Slider(value: $calMs, in: -250...500, step: 1)
                    Text("노트가 소리보다 늦게 오는 느낌이면 −, 빠르면 +. 블루투스 이어폰은 보통 자동 반영만으로도 크게 줄어들고, 남는 차이를 여기서 맞춰요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("기기 출력 지연 자동 반영", isOn: $autoLatency)
                    Text("iOS가 알려주는 출력 지연(이어폰/블루투스)을 자동으로 보정해요. 직접 맞춘 값이 이미 있으면 끄고 조절하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("화면") {
                    Toggle("120fps (ProMotion 기기)", isOn: $fps120)
                    Text("끊김이 느껴지면 끄세요. 기본은 60fps.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("노트 속도: ×\(String(format: "%.2f", speedScale))") {
                    Slider(value: $speedScale, in: 0.6...1.8, step: 0.05)
                }
            }
            .navigationTitle("설정")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("닫기") { dismiss() } } }
        }
    }
}

// MARK: 게임

struct GameSKView: UIViewRepresentable {
    let scene: SKScene
    var fps: Int = 60
    func makeUIView(context: Context) -> SKView {
        let v = SKView()
        v.isMultipleTouchEnabled = true          // 두 손가락 동시 타격
        v.ignoresSiblingOrder = true
        v.preferredFramesPerSecond = fps
        v.presentScene(scene)
        return v
    }
    func updateUIView(_ uiView: SKView, context: Context) {}
}

struct GameView: View {
    @ObservedObject var store: SongStore
    let song: SongInfo
    let course: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("calMs") private var calMs = 0.0
    @AppStorage("speedScale") private var speedScale = 1.0
    @AppStorage("autoLatency") private var autoLatency = true
    @AppStorage("fps120") private var fps120 = false

    enum Phase { case loading(String), playing(GameScene), result(ResultData), failed(String) }
    @State private var phase: Phase = .loading("준비 중…")

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .loading(let m):
                VStack(spacing: 12) { ProgressView(); Text(m).foregroundColor(.white) }
            case .playing(let scene):
                GameSKView(scene: scene, fps: fps120 ? 120 : 60).ignoresSafeArea()
                VStack {
                    HStack {
                        Button { scene.abort(); dismiss() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                    }
                    Spacer()
                }.padding(10)
            case .result(let r):
                ResultView(title: song.displayTitle, course: course, r: r) { dismiss() }
            case .failed(let m):
                VStack(spacing: 14) {
                    Text(m).foregroundColor(.white).multilineTextAlignment(.center)
                    Button("닫기") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding()
            }
        }
        .statusBarHidden(true)
        .task { await prepare() }
        .onDisappear { if case .playing(let sc) = phase { sc.abort() } }
    }

    private func prepare() async {
        do {
            phase = .loading("곡 받는 중…")
            let f = try await store.ensureDownloaded(song)
            phase = .loading("악보 분석·음원 디코딩 중…")
            let course = self.course
            let (chart, buffer, extras) = try await Task.detached(priority: .userInitiated) { () -> (Chart, AVAudioPCMBuffer, [String: AVAudioPCMBuffer]) in
                let data = try Data(contentsOf: f.tja)
                let file = TJAParser.parse(TJAParser.decode(data))
                guard let ch = file.charts[course] else { throw SimpleError("이 난이도 악보를 찾을 수 없어요") }
                // 게임 중 쓰는 효과음/콤보 음성은 여기서 미리 디코딩 (게임 중 디코딩하면 끊김)
                var names = ["se_balloon"]
                var c = 50
                while c <= min(ch.total, 5000) { names.append("v_combo_\(c)"); c += c < 100 ? 50 : 100 }
                return (ch, try AudioDecoder.decode(url: f.audio), GameAudio.decodeExtras(names))
            }.value
            let audio = try GameAudio(music: buffer, extras: extras)
            let b = UIScreen.main.bounds.size
            let aspect = max(b.width, b.height) / min(b.width, b.height)
            let virtualW: CGFloat = aspect >= 16.0 / 9.0 ? 720 * min(aspect, 32.0 / 9.0) : 1280
            let sc = GameScene(size: CGSize(width: virtualW, height: 720))
            sc.scaleMode = .aspectFit
            sc.chart = chart; sc.audio = audio; sc.calMs = calMs; sc.speedScale = speedScale; sc.autoLatency = autoLatency
            let baseStr = await MainActor.run { store.baseURL.absoluteString }
            let key = "\(baseStr)#\(song.id)"
            sc.onFinish = { r in
                var r = r
                let saved = ScoreStore.shared.save(key: key, songID: song.id, title: song.displayTitle,
                                                   difficulty: course, result: r)
                r.crown = saved.crown; r.isRecord = saved.record; r.best = saved.best
                phase = .result(r)
            }
            phase = .playing(sc)
        } catch {
            phase = .failed("불러오기 실패: \(error.localizedDescription)")
        }
    }
}
