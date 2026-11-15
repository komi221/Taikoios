import CoreGraphics
import Foundation

/// vectors.json 의 SVG path (M m L l H h V v C c Z z) → CGPath
enum SVGPath {
    private enum Tok { case cmd(Character), num(CGFloat) }

    private static func tokenize(_ d: String) -> [Tok] {
        var out: [Tok] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter { out.append(.cmd(c)); i += 1; continue }
            if c == "-" || c == "+" || c == "." || c.isNumber {
                var j = i
                if chars[j] == "-" || chars[j] == "+" { j += 1 }
                var seenDot = false
                while j < chars.count {
                    let ch = chars[j]
                    if ch.isNumber { j += 1 }
                    else if ch == "." && !seenDot { seenDot = true; j += 1 }
                    else { break }
                }
                if let v = Double(String(chars[i..<j])) { out.append(.num(CGFloat(v))) }
                i = max(j, i + 1)
                continue
            }
            i += 1
        }
        return out
    }

    static func parse(_ d: String) -> CGPath {
        let toks = tokenize(d)
        let path = CGMutablePath()
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero

        func take(_ n: Int) -> [CGFloat]? {
            var v: [CGFloat] = []
            var k = i
            while v.count < n, k < toks.count, case .num(let x) = toks[k] { v.append(x); k += 1 }
            guard v.count == n else { return nil }
            i = k
            return v
        }

        while i < toks.count {
            if case .cmd(let c) = toks[i] {
                cmd = c; i += 1
                if c == "Z" || c == "z" { path.closeSubpath(); cur = start }
                continue
            }
            let rel = cmd.isLowercase
            switch cmd {
            case "M", "m":
                guard let v = take(2) else { i += 1; continue }
                let p = rel ? CGPoint(x: cur.x + v[0], y: cur.y + v[1]) : CGPoint(x: v[0], y: v[1])
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"
            case "L", "l":
                guard let v = take(2) else { i += 1; continue }
                let p = rel ? CGPoint(x: cur.x + v[0], y: cur.y + v[1]) : CGPoint(x: v[0], y: v[1])
                path.addLine(to: p); cur = p
            case "H", "h":
                guard let v = take(1) else { i += 1; continue }
                let p = CGPoint(x: rel ? cur.x + v[0] : v[0], y: cur.y)
                path.addLine(to: p); cur = p
            case "V", "v":
                guard let v = take(1) else { i += 1; continue }
                let p = CGPoint(x: cur.x, y: rel ? cur.y + v[0] : v[0])
                path.addLine(to: p); cur = p
            case "C", "c":
                guard let v = take(6) else { i += 1; continue }
                let o = rel ? cur : .zero
                let c1 = CGPoint(x: o.x + v[0], y: o.y + v[1])
                let c2 = CGPoint(x: o.x + v[2], y: o.y + v[3])
                let p = CGPoint(x: o.x + v[4], y: o.y + v[5])
                path.addCurve(to: p, control1: c1, control2: c2); cur = p
            default:
                i += 1
            }
        }
        return path
    }
}
