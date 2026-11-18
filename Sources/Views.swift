import SwiftUI
import SpriteKit
import AVFoundation
import UniformTypeIdentifiers
import UIKit

@main
struct TaikoApp: App {
    init() {
        Fonts.register()
        Theme.applyAppearance()
    }
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

/// 2곡 이상 한꺼번에 받을 때 확인창에 쓰는 정보
struct PendingDownload: Identifiable {
    let id = UUID()
    let songs: [SongInfo]
    let bytes: Int64
    let unknown: Int
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
    @State private var pendingDL: PendingDownload?
    @State private var estimating = false
    @AppStorage("hiddenCategories") private var hiddenJSON = "[]"
    @ObservedObject private var scores = ScoreStore.shared
    @ObservedObject private var preview = PreviewPlayer.shared

    private func scoreKey(_ s: SongInfo) -> String { "\(store.baseURL.absoluteString)#\(s.id)" }
    private func crownColor(_ c: String) -> Color { c == "gold" ? (Color(hex: "#ffd43a") ?? .yellow) : Color(white: 0.82) }

    // MARK: 분류 켜기/끄기 (메인 화면 체크 표시)

    private var hiddenSet: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(hiddenJSON.utf8))) ?? [])
    }
    private func categoryOf(_ s: SongInfo) -> String { s.category ?? "기타" }

    private var allCategories: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in store.songs { let c = categoryOf(s); if seen.insert(c).inserted { out.append(c) } }
        return out
    }

    private func saveHidden(_ h: Set<String>) {
        if let d = try? JSONEncoder().encode(Array(h).sorted()), let str = String(data: d, encoding: .utf8) { hiddenJSON = str }
    }
    private func toggleCategory(_ c: String) {
        var h = hiddenSet
        if h.contains(c) { h.remove(c) } else { h.insert(c) }
        saveHidden(h)
    }

    private struct RecentRow: Identifiable {
        let song: SongInfo
        let course: String
        var id: String { "\(song.id)|\(course)" }
    }
    private var recentRows: [RecentRow] {
        let base = store.baseURL.absoluteString
        let hide = hiddenSet
        var out: [RecentRow] = []
        for r in scores.recents where r.key.hasPrefix(base + "#") {
            if let s = store.songs.first(where: { $0.id == r.songID }), !hide.contains(categoryOf(s)),
               s.availableCourses.contains(where: { $0.name == r.course }) {
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
        let hide = hiddenSet
        return store.songs.filter { song in
            if !hide.isEmpty && hide.contains(categoryOf(song)) { return false }
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

    private func makeGroups(_ list: [SongInfo]) -> [SongGroup] {
        var order: [String] = []
        var dict: [String: [SongInfo]] = [:]
        for s in list {
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

    private var chosen: [SongInfo] {
        let hide = hiddenSet
        return store.songs.filter { selected.contains(store.key(for: $0)) && !hide.contains(categoryOf($0)) }
    }

    // MARK: 일괄 다운로드 (2곡 이상이면 총 용량 확인)

    private func startBulkDownload() {
        let todo = chosen.filter { $0.id >= 0 && !store.downloadedIDs.contains(store.key(for: $0)) }
        guard !todo.isEmpty else { store.status = "새로 받을 곡이 없어요"; return }
        if todo.count < 2 { Task { await store.downloadMany(todo) }; return }
        estimating = true
        store.status = "다운로드 용량 확인 중…"
        Task {
            let r = await store.estimateDownloadSize(todo)
            estimating = false
            store.status = ""
            pendingDL = PendingDownload(songs: todo, bytes: r.bytes, unknown: r.unknown)
        }
    }

    private func sizeMessage(_ p: PendingDownload) -> String {
        if p.bytes == 0 { return "총 용량을 확인하지 못했어요. 그래도 다운로드하시겠습니까?" }
        let mb = Double(p.bytes) / 1_000_000
        var m = "총 \(String(format: "%.1f", mb))MB입니다. 다운로드하시겠습니까?"
        if p.unknown > 0 { m += "\n(용량을 확인하지 못한 \(p.unknown)곡은 합계에 없어요)" }
        return m
    }

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
        .listRowSeparatorTint(Color.black.opacity(0.35))
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
        .buttonStyle(TaikoButtonStyle()).disabled(!enabled)
    }

    private var selectionBar: some View {
        let has = !selected.isEmpty
        return VStack(spacing: 8) {
            HStack {
                Text("\(selected.count)곡 선택").font(Theme.title(16)).foregroundColor(.white)
                Spacer()
                Button("전체 선택") { selected = Set(filtered.map { store.key(for: $0) }) }
                    .font(Theme.body(15)).foregroundColor(.white)
                Button("선택 해제") { selected = [] }.disabled(!has)
                    .font(Theme.body(15)).foregroundColor(.white.opacity(has ? 1 : 0.4))
            }
            HStack(spacing: 8) {
                barButton("star.fill", "즐겨찾기", enabled: has) { store.setFavorite(chosen, on: true) }
                barButton("star.slash", "즐겨찾기 해제", enabled: has) { store.setFavorite(chosen, on: false) }
                barButton("arrow.down.circle", estimating ? "확인 중…" : "다운로드", enabled: has && !estimating) { startBulkDownload() }
                barButton("trash", "다운로드 삭제", enabled: has) { confirmDelete = true }
            }
        }
        .padding(12)
        .background(
            ZStack { Theme.red; Color.black.opacity(0.18) }
                .overlay(Rectangle().fill(Theme.redDark).frame(height: 3), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    var body: some View {
        let list = filtered                 // 본문 한 번에 한 번만 계산 (곡이 많아서 여러 번 거르면 느림)
        let grouped = makeGroups(list)
        let hide = hiddenSet
        let cats = allCategories
        NavigationStack {
            List {
                Section {
                    Picker("곡 필터", selection: $listFilter) {
                        Text("전체").tag("전체")
                        Text("다운로드").tag("다운로드")
                        Text("즐겨찾기").tag("즐겨찾기")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)

                    if cats.count > 1 {
                        // 분류 켜기/끄기: 체크 해제한 분류의 곡은 목록·최근 플레이에서 숨김
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(cats, id: \.self) { c in
                                    CategoryChip(name: c, on: !hide.contains(c)) { toggleCategory(c) }
                                }
                                if !hide.isEmpty {
                                    Button { saveHidden([]) } label: {
                                        Text("모두 켜기").font(Theme.body(14)).foregroundColor(.white)
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.red))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                    }
                }
                .listRowSeparator(.hidden)
                if !store.status.isEmpty {
                    Text(store.status).font(Theme.body(13)).foregroundColor(.white.opacity(0.9))
                        .listRowBackground(Color.clear)
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
                            .listRowBackground(Theme.panel)
                        }
                    } header: {
                        TaikoHeader("최근 플레이")
                    }
                }
                ForEach(grouped) { g in
                    Section {
                        ForEach(g.songs) { s in songRow(s) }
                    } header: {
                        TaikoHeader(g.name)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PatternBackground())
            .searchable(text: $query)
            .navigationTitle("Taikoi")
            .navigationBarTitleDisplayMode(.inline)
            .taikoNavBar()
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if store.loading { ProgressView().tint(.white) }
                    Button(selecting ? "완료" : "선택") {
                        selecting.toggle()
                        if !selecting { selected = [] } else { preview.stop() }
                    }
                    .font(Theme.body(16)).foregroundColor(.white)
                    if !selecting {
                        Button { Task { await store.refresh() } } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(.white)
                        }
                        Menu {
                            Button { sheet = .picker } label: { Label("파일 선택 (TJA + 음원)", systemImage: "doc") }
                            Button { sheet = .folderPicker } label: { Label("폴더 선택 (곡 폴더 통째로)", systemImage: "folder") }
                        } label: { Image(systemName: "square.and.arrow.down").foregroundColor(.white) }
                        Button { sheet = .settings } label: { Image(systemName: "gearshape").foregroundColor(.white) }
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
        .alert("\(pendingDL?.songs.count ?? 0)곡 다운로드", isPresented: Binding(
            get: { pendingDL != nil }, set: { if !$0 { pendingDL = nil } }), presenting: pendingDL) { p in
            Button("다운로드") { Task { await store.downloadMany(p.songs) } }
            Button("취소", role: .cancel) {}
        } message: { p in Text(sizeMessage(p)) }
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

// MARK: 설정

struct SettingsView: View {
    @AppStorage("baseURL") private var baseURL = kDefaultBase
    @AppStorage("serversJSON") private var serversJSON = "[\"https://cjdgrevival.com\"]"
    @AppStorage("calMs") private var calMs = 0.0
    @AppStorage("speedScale") private var speedScale = 1.0
    @AppStorage("autoLatency") private var autoLatency = true
    @AppStorage("fps120") private var fps120 = false
    @AppStorage("debugStats") private var debugStats = false
    @AppStorage("renderQuality") private var renderQuality = 0
    @AppStorage("noteInterp") private var noteInterp = 8
    @AppStorage("frameTiming") private var frameTiming = 0
    @AppStorage("bgmOn") private var bgmOn = true
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
                Section {
                    Group {
                        Toggle("메인 화면 배경음악", isOn: $bgmOn)
                        Text("곡 선택 화면에서 흐르는 배경음악을 켜고 끕니다. 게임 중에는 곡 음악만 나와요.")
                            .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                    }
                    .listRowBackground(Theme.panel)
                } header: { TaikoHeader("소리") }

                Section {
                    Group {
                        ForEach(servers, id: \.self) { s in
                            Button { baseURL = s } label: {
                                HStack {
                                    Text(s).foregroundColor(.white)
                                    Spacer()
                                    if s == baseURL { Image(systemName: "checkmark").foregroundColor(Theme.gold) }
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
                    .listRowBackground(Theme.panel)
                } header: { TaikoHeader("곡 서버 (탭해서 선택, 밀어서 삭제)") }

                Section {
                    Group {
                        Slider(value: $calMs, in: -250...500, step: 1)
                        Text("노트가 소리보다 늦게 오는 느낌이면 −, 빠르면 +. 블루투스 이어폰은 보통 자동 반영만으로도 크게 줄어들고, 남는 차이를 여기서 맞춰요.")
                            .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                        Toggle("기기 출력 지연 자동 반영", isOn: $autoLatency)
                        Text("iOS가 알려주는 출력 지연(이어폰/블루투스)을 자동으로 보정해요. 직접 맞춘 값이 이미 있으면 끄고 조절하세요.")
                            .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                    }
                    .listRowBackground(Theme.panel)
                } header: { TaikoHeader("판정 보정: \(Int(calMs)) ms") }

                Section {
                    Group {
                        Picker("해상도", selection: $renderQuality) {
                            Text("높음").tag(0)
                            Text("중간").tag(1)
                            Text("낮음").tag(2)
                        }.pickerStyle(.segmented)
                        Text("낮출수록 화면을 그리는 양이 줄어 끊김이 줄어요. 모션과 효과는 그대로고, 다음 곡부터 적용돼요. 높음은 기기 원래 해상도예요.")
                            .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                        Picker("음표 보간", selection: $noteInterp) {
                            Text("끔").tag(1)
                            Text("약").tag(4)
                            Text("중").tag(8)
                            Text("강").tag(16)
                        }.pickerStyle(.segmented)
                        Text("프레임이 한두 번 빠져도 노트가 한 번에 튀지 않고 부드럽게 이어져요. 판정에는 영향이 없어요.")
                            .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                        if #available(iOS 17.0, *) {
                            Picker("프레임 타이밍", selection: $frameTiming) {
                                Text("표준").tag(0)
                                Text("새 방식").tag(1)
                            }.pickerStyle(.segmented)
                            Text("화면 끊김이나 지연이 느껴질 때 써 보세요 (실험적, iOS 17 이상). 문제가 생기면 표준으로 되돌리세요. 다음 곡부터 적용돼요.")
                                .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                        }
                        Toggle("120fps (ProMotion 기기)", isOn: $fps120)
                        Text("끊김이 느껴지면 끄세요. 기본은 60fps.")
                            .font(Theme.body(12)).foregroundColor(.white.opacity(0.7))
                        Toggle("개발용 측정 표시 (FPS·노드·끊김)", isOn: $debugStats)
                    }
                    .listRowBackground(Theme.panel)
                } header: { TaikoHeader("그래픽") }

                Section {
                    Slider(value: $speedScale, in: 0.6...1.8, step: 0.05)
                        .listRowBackground(Theme.panel)
                } header: { TaikoHeader("노트 속도: ×\(String(format: "%.2f", speedScale))") }
            }
            .foregroundColor(.white)
            .taikoForm()
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .taikoNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }.font(Theme.body(16)).foregroundColor(.white)
                }
            }
            .onChange(of: bgmOn) { on in Bgm.shared.setEnabled(on) }
        }
    }
}

// MARK: 게임

struct GameSKView: UIViewRepresentable {
    let scene: SKScene
    var fps: Int = 60
    var debug: Bool = false
    var quality: Int = 0                         // 해상도: 0 높음(기기 원래) / 1 중간 / 2 낮음
    func makeUIView(context: Context) -> SKView {
        let v = GameSKViewHost()                 // 세 손가락 복사/붙여넣기 막대 방지용 SKView
        v.isMultipleTouchEnabled = true          // 두 손가락 동시 타격
        v.ignoresSiblingOrder = true
        v.preferredFramesPerSecond = fps
        let factor: CGFloat = quality == 1 ? 2.0 / 3.0 : (quality == 2 ? 0.5 : 1.0)
        v.renderScale = max(1, (UIScreen.main.scale * factor * 100).rounded() / 100)
        v.showsFPS = debug; v.showsNodeCount = debug; v.showsDrawCount = debug
        (scene as? GameScene)?.debugStats = debug
        v.presentScene(scene)
        SystemGuard.applyRepeatedly()
        return v
    }
    func updateUIView(_ uiView: SKView, context: Context) {}
}

#if swift(>=5.9)
@available(iOS 17.0, *)
struct MetalGameView: UIViewRepresentable {
    let scene: GameScene
    var fps: Int = 60
    var debug: Bool = false
    var quality: Int = 0
    func makeUIView(context: Context) -> MetalGameHost {
        let v = MetalGameHost(scene: scene, fps: fps)
        let factor: CGFloat = quality == 1 ? 2.0 / 3.0 : (quality == 2 ? 0.5 : 1.0)
        v.renderScale = max(1, (UIScreen.main.scale * factor * 100).rounded() / 100)
        scene.debugStats = debug
        SystemGuard.applyRepeatedly()
        return v
    }
    func updateUIView(_ uiView: MetalGameHost, context: Context) {}
    static func dismantleUIView(_ uiView: MetalGameHost, coordinator: ()) { uiView.stop() }
}
#endif

struct GameView: View {
    @ObservedObject var store: SongStore
    let song: SongInfo
    let course: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("calMs") private var calMs = 0.0
    @AppStorage("speedScale") private var speedScale = 1.0
    @AppStorage("autoLatency") private var autoLatency = true
    @AppStorage("fps120") private var fps120 = false
    @AppStorage("debugStats") private var debugStats = false
    @AppStorage("renderQuality") private var renderQuality = 0
    @AppStorage("noteInterp") private var noteInterp = 8
    @AppStorage("frameTiming") private var frameTiming = 0
    @State private var resumeTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    enum Phase { case loading(String), playing(GameScene), result(ResultData), failed(String) }
    @State private var phase: Phase = .loading("준비 중…")
    @State private var paused = false
    @State private var countdown = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .loading(let m):
                ZStack {
                    PatternBackground()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(m).font(Theme.body(16)).foregroundColor(.white)
                    }
                }
            case .playing(let scene):
                gameSurface(scene).ignoresSafeArea()
                VStack {
                    HStack {
                        Button { scene.abort(); dismiss() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.7))
                        }
                        Button { if scene.pauseGame() { paused = true } } label: {
                            Image(systemName: "pause.circle.fill").font(.title2).foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                    }
                    Spacer()
                }.padding(10)
                if paused { pauseOverlay(scene) }
            case .result(let r):
                ResultView(title: song.displayTitle, course: course, r: r) { dismiss() }
            case .failed(let m):
                ZStack {
                    PatternBackground()
                    VStack(spacing: 14) {
                        Text(m).font(Theme.body(16)).foregroundColor(.white).multilineTextAlignment(.center)
                        Button { dismiss() } label: {
                            Text("닫기").font(Theme.title(18)).padding(.horizontal, 28).padding(.vertical, 10)
                        }
                        .buttonStyle(TaikoButtonStyle(prominent: true))
                    }.padding()
                }
            }
        }
        .statusBarHidden(true)
        .task { await prepare() }
        .onDisappear { if case .playing(let sc) = phase { sc.abort() } }
        // 앱을 나가면(홈/앱 전환) 곡 소리가 계속 나지 않게 게임을 일시정지함
        .onChange(of: scenePhase) { p in if p == .background { leaveForBackground() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in leaveForBackground() }
    }

    /// 게임 화면: 기본은 SKView, 설정에서 "새 방식"을 고르면(iOS 17 이상) 직접 그리는 Metal 호스트
    @ViewBuilder
    private func gameSurface(_ scene: SKScene) -> some View {
        #if swift(>=5.9)
        if #available(iOS 17.0, *), frameTiming == 1, let gs = scene as? GameScene {
            MetalGameView(scene: gs, fps: fps120 ? 120 : 60, debug: debugStats, quality: renderQuality)
        } else {
            GameSKView(scene: scene, fps: fps120 ? 120 : 60, debug: debugStats, quality: renderQuality)
        }
        #else
        GameSKView(scene: scene, fps: fps120 ? 120 : 60, debug: debugStats, quality: renderQuality)
        #endif
    }

    private func pauseOverlay(_ scene: GameScene) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            if countdown > 0 {
                Text("\(countdown)").font(Theme.title(96)).foregroundColor(.white)
            } else {
                VStack(spacing: 14) {
                    Text("일시정지").font(Theme.title(28)).foregroundColor(.white)
                    Button { resumeWithCountdown(scene) } label: {
                        Text("계속하기").font(Theme.title(18)).padding(.horizontal, 28).padding(.vertical, 10)
                    }.buttonStyle(TaikoButtonStyle(prominent: true))
                    Button { restart(scene) } label: {
                        Text("처음부터").font(Theme.title(18)).padding(.horizontal, 28).padding(.vertical, 10)
                    }.buttonStyle(TaikoButtonStyle())
                    Button { scene.abort(); dismiss() } label: {
                        Text("나가기").font(Theme.title(18)).padding(.horizontal, 28).padding(.vertical, 10)
                    }.buttonStyle(TaikoButtonStyle())
                }
            }
        }
    }

    /// 3·2·1 뒤에 이어서 재생 (그 사이에는 곡도 노트도 멈춰 있음)
    private func resumeWithCountdown(_ scene: GameScene) {
        guard countdown == 0 else { return }
        resumeTask = Task { @MainActor in
            for n in [3, 2, 1] {
                countdown = n
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { countdown = 0; return }     // 카운트다운 중 앱을 나간 경우
            }
            countdown = 0
            paused = false
            scene.resumeGame()
        }
    }

    private func restart(_ scene: GameScene) {
        scene.abort()
        paused = false; countdown = 0
        phase = .loading("준비 중…")
        Task { await prepare() }
    }

    private func leaveForBackground() {
        resumeTask?.cancel(); resumeTask = nil; countdown = 0
        guard case .playing(let sc) = phase else { dismiss(); return }
        if sc.isGamePaused { paused = true; return }       // 이미 멈춰 있음 (알림이 두 번 올 때)
        if sc.pauseGame() { paused = true; return }
        sc.abort(); dismiss()                              // 곡 시작 전 대기 중이면 예전처럼 종료
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
            sc.interpN = Double(noteInterp)
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
