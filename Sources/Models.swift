
import Foundation

let kDefaultBase = "https://cjdgrevival.com"

struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct TitleLang: Codable {
    var ja: String?
    var en: String?
    var ko: String?
}

struct CourseInfo: Codable {
    var branch: Bool?
    var stars: Int?
}

struct SongInfo: Codable, Identifiable, Hashable {
    // 서버 ID는 숫자가 아닌 해시 문자열
    var id: String
    var title: String
    var subtitle: String?
    var title_lang: TitleLang?
    var category: String?
    var category_id: Int?
    var courses: [String: CourseInfo?]?
    var music_type: String?

    // taiko.asia의 order는 문자열
    var order: String?

    static func == (a: SongInfo, b: SongInfo) -> Bool {
        a.id == b.id
    }

    func hash(into h: inout Hasher) {
        h.combine(id)
    }

    var isLocal: Bool {
        id.hasPrefix("local-")
    }

    var displayTitle: String {
        if let k = title_lang?.ko, !k.isEmpty { return k }
        if let j = title_lang?.ja, !j.isEmpty { return j }
        return title
    }

    var audioExt: String {
        music_type ?? "mp3"
    }

    var availableCourses: [CourseEntry] {
        ["easy", "normal", "hard", "oni", "ura"].compactMap { k in
            if let c = courses?[k], let info = c {
                return CourseEntry(name: k, stars: info.stars ?? 0)
            }
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
