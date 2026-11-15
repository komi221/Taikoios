import Foundation

struct Note {
    var time: Double          // 음원 기준 ms
    var type: Int             // 0 마디선, 1 돈, 2 카, 3 큰돈, 4 큰카, 5 연타, 6 큰연타, 7 풍선
    var speed: Double         // bpm * scroll
    var endTime: Double = 0
    var balloon: Int = 0
}

final class Chart {
    var course: String
    var level: Int
    var notes: [Note] = []
    var total = 0
    var beatMs = 500.0
    var gogo: [(Double, Double)] = []
    init(course: String, level: Int) { self.course = course; self.level = level }
}

struct TJAFile {
    var title = ""
    var subtitle = ""
    var charts: [String: Chart] = [:]
}

enum TJAParser {
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func normalizeCourse(_ s: String) -> String {
        switch s.lowercased() {
        case "0", "easy": return "easy"
        case "1", "normal": return "normal"
        case "2", "hard": return "hard"
        case "3", "oni": return "oni"
        case "4", "edit", "ura": return "ura"
        default: return "oni"
        }
    }

    private static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "//") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ text: String) -> TJAFile {
        var file = TJAFile()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var bpm = 120.0, offsetSec = 0.0
        var course = "oni", level = 0
        var balloons: [Int] = []
        var i = 0
        while i < lines.count {
            let line = clean(lines[i]); i += 1
            if line.isEmpty { continue }
            let up = line.uppercased()
            if up.hasPrefix("#START") {
                var body: [String] = []
                while i < lines.count {
                    let l = clean(lines[i]); i += 1
                    if l.uppercased().hasPrefix("#END") { break }
                    if !l.isEmpty { body.append(l) }
                }
                if up.contains("P2") { continue }
                let chart = buildChart(body, bpm: bpm, offsetMs: -offsetSec * 1000,
                                       balloons: balloons, course: course, level: level)
                file.charts[course] = chart
                balloons = []
                continue
            }
            if !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].uppercased().trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "TITLE": file.title = val
                case "SUBTITLE": file.subtitle = val.hasPrefix("--") ? String(val.dropFirst(2)) : val
                case "BPM": bpm = Double(val) ?? 120
                case "OFFSET": offsetSec = Double(val) ?? 0
                case "COURSE": course = normalizeCourse(val)
                case "LEVEL": level = Int(Double(val) ?? 0)
                case "BALLOON": balloons = val.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
                default: break
                }
            }
        }
        return file
    }

    static func buildChart(_ body: [String], bpm startBpm: Double, offsetMs: Double,
                           balloons: [Int], course: String, level: Int) -> Chart {
        let chart = Chart(course: course, level: level)
        var notes: [Note] = []
        var time = offsetMs
        var bpm = startBpm > 0 ? startBpm : 120
        var scroll = 1.0
        var barOn = true
        var num = 4.0, den = 4.0
        var skip = false
        var chars: [Character] = []
        var cmds: [(Int, String, String)] = []
        var balloonIdx = 0
        var pending: Int? = nil
        var total = 0
        var gogoStart: Double? = nil
        var gogoRanges: [(Double, Double)] = []

        func apply(_ name: String, _ arg: String) {
            switch name {
            case "BPMCHANGE": if let v = Double(arg), v > 0 { bpm = v }
            case "SCROLL": if let v = Double(arg) { scroll = v }
            case "DELAY": time += (Double(arg) ?? 0) * 1000
            case "BARLINEOFF": barOn = false
            case "BARLINEON": barOn = true
            case "GOGOSTART": gogoStart = time
            case "GOGOEND": if let g = gogoStart { gogoRanges.append((g, time)); gogoStart = nil }
            default: break
            }
        }

        func flush() {
            let n = chars.count
            let beats = 4.0 * num / den
            for idx in 0...n {
                for c in cmds where c.0 == idx { apply(c.1, c.2) }
                if idx == 0 && barOn { notes.append(Note(time: time, type: 0, speed: bpm * scroll)) }
                if idx < n {
                    let ch = chars[idx]
                    let sp = bpm * scroll
                    switch ch {
                    case "1", "2", "3", "4":
                        notes.append(Note(time: time, type: Int(String(ch)) ?? 1, speed: sp)); total += 1
                    case "A": notes.append(Note(time: time, type: 3, speed: sp)); total += 1
                    case "B": notes.append(Note(time: time, type: 4, speed: sp)); total += 1
                    case "5", "6":
                        notes.append(Note(time: time, type: Int(String(ch)) ?? 5, speed: sp))
                        pending = notes.count - 1
                    case "7", "9":
                        let hits = balloonIdx < balloons.count ? balloons[balloonIdx] : 5
                        balloonIdx += 1
                        notes.append(Note(time: time, type: 7, speed: sp, balloon: hits))
                        pending = notes.count - 1
                    case "8":
                        if let p = pending { notes[p].endTime = time; pending = nil }
                    default: break
                    }
                    time += beats * 60000 / bpm / Double(n)
                }
            }
            if n == 0 { time += beats * 60000 / bpm }
            chars = []; cmds = []
        }

        for line in body {
            if line.hasPrefix("#") {
                let parts = line.dropFirst().split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                let name = parts.first.map { String($0).uppercased() } ?? ""
                let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                switch name {
                case "N", "BRANCHSTART", "BRANCHEND": skip = false
                case "E", "M": skip = true
                case "MEASURE":
                    if !skip {
                        let p = arg.split(separator: "/")
                        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { num = a; den = b }
                    }
                default:
                    if !skip { cmds.append((chars.count, name, arg)) }
                }
                continue
            }
            if skip { continue }
            for ch in line {
                if ch == "," { flush() }
                else if "0123456789AB".contains(ch) { chars.append(ch) }
            }
        }
        if !chars.isEmpty || !cmds.isEmpty { flush() }
        if let p = pending { notes[p].endTime = time }
        for k in notes.indices where notes[k].type >= 5 && notes[k].endTime < notes[k].time {
            notes[k].endTime = notes[k].time + 500
        }
        if let g = gogoStart { gogoRanges.append((g, time)) }
        notes.sort { $0.time < $1.time }
        chart.gogo = gogoRanges
        chart.beatMs = 60000 / (startBpm > 0 ? startBpm : 120)
        chart.notes = notes
        chart.total = total
        return chart
    }
}
