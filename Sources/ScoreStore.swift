import Foundation

struct ScoreEntry: Codable {
    var crown: String = ""        // "", "silver", "gold"
    var points = 0, good = 0, ok = 0, bad = 0, maxCombo = 0, drumroll = 0
}

struct SongScores: Codable {
    var title: String = ""
    var byDifficulty: [String: ScoreEntry] = [:]
}

struct RecentPlay: Codable, Identifiable {
    var key: String
    var songID: Int
    var title: String
    var course: String
    var date: Date
    var id: String { key + "|" + course }
}

/// taiko-web scoresheet.saveScore() 와 같은 저장 규칙
/// - 같은 곡·난이도의 기존 점수 이하일 때만 기록 갱신
/// - 게이지 클리어 시: 不可 0 이면 gold, 아니면 silver. 기존의 더 높은 왕관은 유지
final class ScoreStore: ObservableObject {
    static let shared = ScoreStore()
    @Published private(set) var scores: [String: SongScores] = [:]
    @Published private(set) var recents: [RecentPlay] = []

    private var recentFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recents.json")
    }

    private var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("scores.json")
    }

    init() {
        if let d = try? Data(contentsOf: file),
           let s = try? JSONDecoder().decode([String: SongScores].self, from: d) { scores = s }
        if let d = try? Data(contentsOf: recentFile),
           let r = try? JSONDecoder().decode([RecentPlay].self, from: d) { recents = r }
    }

    func best(_ key: String) -> [String: ScoreEntry] { scores[key]?.byDifficulty ?? [:] }

    func get(_ key: String, _ difficulty: String) -> ScoreEntry? { scores[key]?.byDifficulty[difficulty] }

    /// 저장하고, 화면에 보여줄 (최종 왕관, 신기록 여부, 최고점) 을 돌려준다
    @discardableResult
    func save(key: String, songID: Int, title: String, difficulty: String, result r: ResultData) -> (crown: String, record: Bool, best: Int) {
        var crown = ""
        if r.cleared { crown = (r.bad + r.miss) == 0 ? "gold" : "silver" }
        var entry = ScoreEntry(crown: crown, points: max(0, r.score), good: r.good, ok: r.ok,
                               bad: r.bad + r.miss, maxCombo: r.maxCombo, drumroll: r.rollHits)
        var song = scores[key] ?? SongScores()
        song.title = title
        var record = false
        var finalCrown = crown
        if let old = song.byDifficulty[difficulty] {
            if old.points <= entry.points {
                if old.crown == "gold" || (old.crown == "silver" && crown.isEmpty) { entry.crown = old.crown }
                song.byDifficulty[difficulty] = entry
                record = old.points < entry.points
                finalCrown = entry.crown
            } else {
                var o = old
                if (crown == "gold" && old.crown != "gold") || (!crown.isEmpty && old.crown.isEmpty) { o.crown = crown }
                song.byDifficulty[difficulty] = o
                finalCrown = o.crown
            }
        } else {
            song.byDifficulty[difficulty] = entry
            record = entry.points > 0
        }
        scores[key] = song
        if let d = try? JSONEncoder().encode(scores) { try? d.write(to: file, options: .atomic) }

        // 최근 플레이 (같은 곡·난이도는 맨 앞으로, 최대 20개)
        recents.removeAll { $0.key == key && $0.course == difficulty }
        recents.insert(RecentPlay(key: key, songID: songID, title: title, course: difficulty, date: Date()), at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        if let d = try? JSONEncoder().encode(recents) { try? d.write(to: recentFile, options: .atomic) }
        return (finalCrown, record, song.byDifficulty[difficulty]?.points ?? entry.points)
    }
}
