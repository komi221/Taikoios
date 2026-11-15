import Foundation

let kDefaultBase = "https://cjdgrevival.com"
let kTaikoAsiaBase = "https://taiko.asia"

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
    /// 앱 내부 키. 서버 id 가 숫자면 그대로, 문자열(taiko.asia 의 해시 id)이면 안정적인 양수 해시.
    var id: Int
    var title: String
    var subtitle: String?
    var title_lang: TitleLang?
    var category: String?
    var category_id: Int?
    var courses: [String: CourseInfo?]?
    var music_type: String?
    var order: Int?
    /// 서버가 주는 진짜 id (파일 주소에 사용). 가져온 곡은 nil.
    var sid: String? = nil
    /// 미리듣기 시작 지점(초). 서버가 주면 사용.
    var preview: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, sid, title, subtitle, title_lang, category, category_id, courses, music_type, order, preview
    }

    /// 파일 주소/폴더 이름에 쓰는 서버 id
    var serverID: String { sid ?? String(id) }

    /// 문자열 id → 안정적인 양수 Int (FNV-1a)
    static func stableID(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(h & 0x3FFF_FFFF_FFFF_FFFF) | 1
    }

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

extension SongInfo {
    /// id / order 가 숫자든 문자열이든(taiko.asia) 곡이 버려지지 않게 받는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Int.self, forKey: .id) {
            id = n
            sid = (try? c.decodeIfPresent(String.self, forKey: .sid)) ?? String(n)
        } else if let str = try? c.decode(String.self, forKey: .id), !str.isEmpty {
            if let n = Int(str) { id = n } else { id = SongInfo.stableID(str) }
            sid = str
        } else {
            throw SimpleError("id 없음")
        }
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        title_lang = try? c.decodeIfPresent(TitleLang.self, forKey: .title_lang)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        category_id = try? c.decodeIfPresent(Int.self, forKey: .category_id)
        courses = try? c.decodeIfPresent([String: CourseInfo?].self, forKey: .courses)
        music_type = try? c.decodeIfPresent(String.self, forKey: .music_type)
        order = try? c.decodeIfPresent(Int.self, forKey: .order)     // 문자열이면 nil
        preview = try? c.decodeIfPresent(Double.self, forKey: .preview)
    }
}

extension SongInfo {
    /// JSON 딕셔너리에서 직접 만든다 (id/order 가 숫자·문자열·null 무엇이든, 필드가 이상해도 곡을 버리지 않음)
    static func make(from d: [String: Any]) -> SongInfo? {
        func str(_ v: Any?) -> String? {
            if let s = v as? String { return s.isEmpty ? nil : s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String { return Int(s) }
            return nil
        }
        let titleStr = str(d["title"])
        guard let sidStr = str(d["id"]) ?? str(d["hash"]) ?? titleStr else { return nil }
        let id: Int = { if let n = Int(sidStr), n >= 0 { return n }; return SongInfo.stableID(sidStr) }()
        var tl: TitleLang? = nil
        if let t = d["title_lang"] as? [String: Any] {
            tl = TitleLang(ja: str(t["ja"]), en: str(t["en"]), ko: str(t["ko"]))
        }
        var courses: [String: CourseInfo?] = [:]
        if let c = d["courses"] as? [String: Any] {
            for (k, v) in c {
                if let cd = v as? [String: Any] {
                    courses[k] = CourseInfo(branch: cd["branch"] as? Bool, stars: int(cd["stars"]))
                }
            }
        }
        var s = SongInfo(id: id, title: titleStr ?? sidStr, subtitle: str(d["subtitle"]), title_lang: tl,
                         category: str(d["category"]), category_id: int(d["category_id"]),
                         courses: courses, music_type: str(d["music_type"]), order: int(d["order"]))
        s.sid = sidStr
        s.preview = (d["preview"] as? NSNumber)?.doubleValue
        return s
    }

    /// 서버 응답 전체를 읽는다. (곡 목록, 못 읽은 개수, 못 읽은 항목 예시)
    static func parseList(_ data: Data) -> (songs: [SongInfo], skipped: Int, sample: String) {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return ([], 0, "JSON 형식이 아님") }
        var arr = any as? [Any]
        if arr == nil, let dict = any as? [String: Any] {
            for k in ["songs", "data", "items", "results"] { if let a = dict[k] as? [Any] { arr = a; break } }
        }
        guard let list = arr else { return ([], 0, "목록 형식을 알 수 없음") }
        var out: [SongInfo] = []
        var skipped = 0
        var sample = ""
        for item in list {
            if let d = item as? [String: Any], let s = make(from: d) { out.append(s) }
            else { skipped += 1; if sample.isEmpty { sample = String(String(describing: item).prefix(100)) } }
        }
        return (out, skipped, sample)
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
