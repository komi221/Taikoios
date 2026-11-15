import SwiftUI
import SpriteKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct TaikoApp: App {
    init() { Fonts.register() }
    var body: some Scene {
        WindowGroup { SongListView().preferredColorScheme(.dark) }
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

    private var filtered: [SongInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return store.songs }
        return store.songs.filter {
            $0.title.lowercased().contains(q) || $0.displayTitle.lowercased().contains(q)
                || ($0.title_lang?.ja ?? "").lowercased().contains(q)
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
                if !store.status.isEmpty {
                    Text(store.status).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(groups) { g in
                    Section {
                        ForEach(g.songs) { s in
                            Button { dialogSong = s } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(s.displayTitle).font(.custom(Fonts.kozuka, size: 19)).foregroundColor(.white)
                                        if store.isDownloaded(s) {
                                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption)
                                        }
                                    }
                                    if let sub = s.subtitle, !sub.isEmpty {
                                        Text(sub).font(.custom(Fonts.kozuka, size: 12)).foregroundColor(.white.opacity(0.8))
                                    }
                                    Text(s.availableCourses.map { "\(courseLabel($0.name))★\($0.stars)" }.joined(separator: "  "))
                                        .font(.caption2).foregroundColor(.yellow)
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
        .confirmationDialog(dialogSong?.displayTitle ?? "", isPresented: Binding(
            get: { dialogSong != nil }, set: { if !$0 { dialogSong = nil } }), titleVisibility: .visible,
            presenting: dialogSong) { song in
            ForEach(song.availableCourses) { c in
                Button("\(courseLabel(c.name))  ★\(c.stars)") { play = PlayTarget(song: song, course: c.name) }
            }
        }
        .fullScreenCover(item: $play) { t in GameView(store: store, song: t.song, course: t.course) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { store.importLocal(urls: urls) }
        }
    }
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
                    Slider(value: $calMs, in: -150...150, step: 1)
                    Text("노트가 소리보다 늦게 오는 느낌이면 −, 빠르면 +").font(.footnote).foregroundStyle(.secondary)
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
    func makeUIView(context: Context) -> SKView {
        let v = SKView()
        v.isMultipleTouchEnabled = true          // 두 손가락 동시 타격
        v.ignoresSiblingOrder = true
        v.preferredFramesPerSecond = 120
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

    enum Phase { case loading(String), playing(GameScene), result(ResultData), failed(String) }
    @State private var phase: Phase = .loading("준비 중…")

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .loading(let m):
                VStack(spacing: 12) { ProgressView(); Text(m).foregroundColor(.white) }
            case .playing(let scene):
                GameSKView(scene: scene).ignoresSafeArea()
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
            let (chart, buffer) = try await Task.detached(priority: .userInitiated) { () -> (Chart, AVAudioPCMBuffer) in
                let data = try Data(contentsOf: f.tja)
                let file = TJAParser.parse(TJAParser.decode(data))
                guard let ch = file.charts[course] else { throw SimpleError("이 난이도 악보를 찾을 수 없어요") }
                return (ch, try AudioDecoder.decode(url: f.audio))
            }.value
            let audio = try GameAudio(music: buffer)
            let b = UIScreen.main.bounds.size
            let aspect = max(b.width, b.height) / min(b.width, b.height)
            let virtualW: CGFloat = aspect >= 16.0 / 9.0 ? 720 * min(aspect, 32.0 / 9.0) : 1280
            let sc = GameScene(size: CGSize(width: virtualW, height: 720))
            sc.scaleMode = .aspectFit
            sc.chart = chart; sc.audio = audio; sc.calMs = calMs; sc.speedScale = speedScale
            sc.onFinish = { r in phase = .result(r) }
            phase = .playing(sc)
        } catch {
            phase = .failed("불러오기 실패: \(error.localizedDescription)")
        }
    }
}

struct ResultView: View {
    let title: String
    let course: String
    let r: ResultData
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.custom(Fonts.tnt, size: 28))
            Text("\(courseLabel(course)) – \(r.cleared ? "CLEAR" : "FAILED")")
                .font(.headline).foregroundColor(r.cleared ? .yellow : .gray)
            Text("\(r.score)").font(.custom(Fonts.tnt, size: 52))
            HStack(spacing: 24) {
                stat("GOOD", r.good); stat("OK", r.ok); stat("BAD", r.bad); stat("MISS", r.miss)
                stat("연타", r.rollHits); stat("최대콤보", r.maxCombo)
            }
            Text("게이지 \(Int(r.gaugePercent * 100))%").foregroundColor(.secondary)
            Button("곡 목록으로", action: close).buttonStyle(.borderedProminent).padding(.top, 8)
        }
        .foregroundColor(.white)
    }

    private func stat(_ k: String, _ v: Int) -> some View {
        VStack { Text(k).font(.caption).foregroundColor(.secondary); Text("\(v)").font(.title3.bold()) }
    }
}
