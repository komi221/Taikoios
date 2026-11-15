import Foundation

let kDefaultBase = "https://cjdgrevival.com"

struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// 한 곡이 깨져 있어도 전체 목록 디코딩이 실패하지 않게
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct TitleLang: Codable { var ja: String?; var en: String?; var ko: String? }
struct CourseInfo: Codable { var branch: Bool?; var stars: Int? }

struct SongInfo: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var subtitle: String?
    var title_lang: TitleLang?
    var category: String?
    var category_id: Int?
    var courses: [String: CourseInfo?]?
    var music_type: String?
    var order: Int?

    static func == (a: SongInfo, b: SongInfo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var displayTitle: String {
        if let k = title_lang?.ko, !k.isEmpty { return k }
        if let j = title_lang?.ja, !j.isEmpty { return j }
        return title
    }
    var audioExt: String { music_type ?? "mp3" }

    var availableCourses: [CourseEntry] {
        ["easy", "normal", "hard", "oni", "ura"].compactMap { k in
            if let c = courses?[k], let info = c { return CourseEntry(name: k, stars: info.stars ?? 0) }
            return nil
        }
    }
}

struct CourseEntry: Identifiable {
    let name: String
    let stars: Int
    var id: String { name }
}

struct SongGroup: Identifiable {
    let name: String
    let songs: [SongInfo]
    var id: String { name }
}

func courseLabel(_ c: String) -> String {
    switch c {
    case "easy": return "쉬움"
    case "normal": return "보통"
    case "hard": return "어려움"
    case "oni": return "오니"
    case "ura": return "우라"
    default: return c
    }
}


struct ScoreRecord: Codable {
    var result: ResultData
    var updatedAt: Date
}

enum BestScoreStore {
    private static let key = "taiko.bestScores.v1"

    private static func storage() -> [String: ScoreRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode([String: ScoreRecord].self, from: data) else { return [:] }
        return value
    }

    static func best(song: SongInfo, course: String) -> ScoreRecord? {
        storage()["\\(song.id):\\(course)"]
    }

    @discardableResult
    static func save(_ result: ResultData, song: SongInfo, course: String) -> ScoreRecord {
        var all = storage()
        let id = "\\(song.id):\\(course)"
        let previous = all[id]
        if previous == nil || result.score >= previous!.result.score {
            all[id] = ScoreRecord(result: result, updatedAt: Date())
            if let data = try? JSONEncoder().encode(all) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        return all[id] ?? ScoreRecord(result: result, updatedAt: Date())
    }
}
