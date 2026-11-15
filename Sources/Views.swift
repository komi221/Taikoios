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
    enum ActiveSheet: String, Identifiable { case settings, share, picker, folderPicker; var id: String { rawValue } }

    @StateObject private var store = SongStore()
    @AppStorage("baseURL") private var baseURL = kDefaultBase
    @State private var query = ""
    @State private var dialogSong: SongInfo?
    @State private var play: PlayTarget?
    @State private var sheet: ActiveSheet?
    @State private var listFilter = "전체"
    @State private var shareURLs: [URL] = []
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var importMessage: String?
    @ObservedObject private var scores = ScoreStore.shared
    @ObservedObject private var preview = PreviewPlayer.shared

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

    /// 선택창이 닫힌 뒤에 결과 알림을 띄운다 (닫히는 중에 띄우면 무시될 수 있음)
    private func showImport(_ m: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { importMessage = m }
    }

    private var chosen: [SongInfo] { store.songs.filter { selected.contains(store.key(for: $0)) } }

    // MARK: 곡 한 줄

    @ViewBuilder private func songRow(_ s: SongInfo) -> some View {
        let key = store.key(for: s)
        let isSel = selected.contains(key)
        let isDown = store.downloadedIDs.contains(key)
        let isFav = store.favoriteIDs.contains(key)
        let busy = store.downloadingIDs.contains(key)
        let previewing = preview.playingKey == key
        let previewLoading = preview.loadingKey == key
        HStack(spacing: 8) {
            if selecting {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 30))
                    .foregroundStyle(isSel ? Color.green : Color.white.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.displayTitle).font(.custom(Fonts.kozuka, size: 19)).foregroundColor(.white)
                    if isDown { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption) }
                    if previewing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.yellow).font(.caption) }
                    if previewLoading { ProgressView().scaleEffect(0.7) }
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
            .onTapGesture {
                if selecting {
                    if isSel { selected.remove(key) } else { selected.insert(key) }
                } else {
                    preview.stop()
                    dialogSong = s
                }
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                guard !selecting else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                preview.toggle(key: key, startSec: s.preview) { await store.previewAudioURL(s) }
            }
            if !selecting {
                Button { store.toggleFavorite(s) } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 28))
                        .foregroundStyle(isFav ? Color.yellow : Color.white)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).accessibilityLabel("즐겨찾기")
                if isDown {
                    Button {
                        shareURLs = store.exportFiles(for: s)
                        if !shareURLs.isEmpty { sheet = .share }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 26)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).accessibilityLabel("곡 내보내기")
                } else {
                    Button { Task { await store.download(s) } } label: {
                        Group {
                            if busy { ProgressView() }
                            else { Image(systemName: "arrow.down.circle").font(.system(size: 28)).foregroundStyle(.white) }
                        }
                        .frame(width: 56, height: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).disabled(busy || s.id < 0)
                    .accessibilityLabel("곡 다운로드")
                }
            }
        }
        .listRowBackground(rowColor(s, selected: isSel))
    }

    private func rowColor(_ s: SongInfo, selected: Bool) -> Color {
        if selected { return Color.green.opacity(0.4) }
        if let c = store.categoryColors[s.category_id ?? -99] { return c.opacity(0.9) }
        return Color(white: 0.15)
    }

    // MARK: 일괄 작업 바

    private func barButton(_ icon: String, _ title: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered).disabled(!enabled)
    }

    private var selectionBar: some View {
        let has = !selected.isEmpty
        return VStack(spacing: 8) {
            HStack {
                Text("\(selected.count)곡 선택").font(.subheadline.bold())
                Spacer()
                Button("전체 선택") { selected = Set(filtered.map { store.key(for: $0) }) }
                Button("선택 해제") { selected = [] }.disabled(!has)
            }
            HStack(spacing: 8) {
                barButton("star.fill", "즐겨찾기", enabled: has) { store.setFavorite(chosen, on: true) }
                barButton("star.slash", "즐겨찾기 해제", enabled: has) { store.setFavorite(chosen, on: false) }
                barButton("arrow.down.circle", "다운로드", enabled: has) { Task { await store.downloadMany(chosen) } }
                barButton("trash", "다운로드 삭제", enabled: has) { confirmDelete = true }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
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
                if listFilter == "전체" && query.trimmingCharacters(in: .whitespaces).isEmpty && !recentRows.isEmpty && !selecting {
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
                        ForEach(g.songs) { s in songRow(s) }
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
                    Button(selecting ? "완료" : "선택") {
                        selecting.toggle()
                        if !selecting { selected = [] } else { preview.stop() }
                    }
                    if !selecting {
                        Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        Menu {
                            Button { sheet = .picker } label: { Label("파일 선택 (TJA + 음원)", systemImage: "doc") }
                            Button { sheet = .folderPicker } label: { Label("폴더 선택 (곡 폴더 통째로)", systemImage: "folder") }
                        } label: { Image(systemName: "square.and.arrow.down") }
                        Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .task { await store.refresh() }
        }
        .onChange(of: baseURL) { _ in
            preview.stop(); selected = []
            store.switchServer()
        }
        .onAppear {
            Bgm.shared.play("bgm_songsel")
            Sfx.shared.preload(["se_don", "se_gameclear", "se_gamefail", "v_results"])
        }
        .onChange(of: play?.id) { id in
            if id == nil { Bgm.shared.play("bgm_songsel") }
            else { preview.stop(resumeBgm: false); Bgm.shared.stop() }
        }
        .confirmationDialog(dialogSong?.displayTitle ?? "", isPresented: Binding(
            get: { dialogSong != nil }, set: { if !$0 { dialogSong = nil } }), titleVisibility: .visible,
            presenting: dialogSong) { song in
            ForEach(song.availableCourses) { c in
                Button("\(courseLabel(c.name))  ★\(c.stars)") { play = PlayTarget(song: song, course: c.name) }
            }
        }
        .alert("선택한 \(selected.count)곡의 다운로드 파일을 삭제할까요?", isPresented: $confirmDelete) {
            Button("삭제", role: .destructive) { store.deleteDownloads(chosen) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("가져온 곡은 원본이 없어져서 삭제되지 않아요. 서버 곡은 나중에 다시 받을 수 있어요.")
        }
        .alert("파일 가져오기", isPresented: Binding(
            get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
        .fullScreenCover(item: $play) { t in GameView(store: store, song: t.song, course: t.course) }
        .sheet(item: $sheet) { which in
            switch which {
            case .settings: SettingsView()
            case .share: ActivityShareSheet(items: shareURLs)
            case .picker:
                DocumentPicker(folder: false) { urls in
                    sheet = nil
                    if !urls.isEmpty { let m = store.importLocal(urls: urls); showImport(m) }
                }
            case .folderPicker:
                DocumentPicker(folder: true) { urls in
                    sheet = nil
                    if let f = urls.first { let m = store.importFolder(f); showImport(m) }
                }
            }
        }
    }
}

/// 파일 앱에서 TJA + 음원을 고르는 선택기. asCopy 로 앱 안에 복사해 오기 때문에
/// 보안 범위(security-scoped) 접근 문제 없이 읽을 수 있다.
struct DocumentPicker: UIViewControllerRepresentable {
    var folder = false
    let onPick: ([URL]) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = folder
            ? UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            : UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.allowsMultipleSelection = !folder
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ f: @escaping ([URL]) -> Void) { onPick = f }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick([]) }
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
                    if !servers.contains(kTaikoAsiaBase) {
                        Button("taiko.asia 서버 추가") {
                            save(servers + [kTaikoAsiaBase])
                            baseURL = kTaikoAsiaBase
                        }
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
