import UIKit
import CoreGraphics

/// 원본 logo.js 를 그대로 옮긴 타이틀 로고 (vectors.json 의 logo1~5 경로 사용)
enum LogoRenderer {
    static let image: UIImage = render()

    private struct Sym {
        let x: CGFloat, y: CGFloat
        let scale: Bool
        let path: CGPath
        let shadow: CGPath?
    }

    private static func vectors() -> [String: String] {
        guard let u = Bundle.main.url(forResource: "vectors", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }

    private static func gradient(_ a: String, _ b: String) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: [UIColor(hexString: a).cgColor, UIColor(hexString: b).cgColor] as CFArray,
                   locations: [0, 1])!
    }

    private static let subtitleColors = ["#df600d", "#d8446f", "#b2147b", "#428ac2", "#1f9099"]

    private static func subtitleColor(_ index: Int) -> UIColor {
        var idx = index, sign = 1, pos = 0
        let length = subtitleColors.count - 1
        while idx >= 0 {
            pos = sign == 1 ? idx % length : length - (idx % length)
            sign *= -1
            idx -= length
        }
        return UIColor(hexString: subtitleColors[pos])
    }

    private static func render() -> UIImage {
        let v = vectors()
        func P(_ k: String) -> CGPath { SVGPath.parse(v[k] ?? "") }
        let syms: [Sym] = [
            Sym(x: 315, y: 18, scale: true, path: P("logo5"), shadow: nil),
            Sym(x: 267, y: 50, scale: true, path: P("logo4"), shadow: nil),
            Sym(x: 197, y: 7, scale: true, path: P("logo3"), shadow: nil),
            Sym(x: 87, y: 7, scale: false, path: P("logo2"), shadow: P("logo2Shadow")),
            Sym(x: 22, y: 16, scale: false, path: P("logo1"), shadow: nil)
        ]

        // 부제목 "たいこウェブ" 글자 배치
        var letters: [(s: String, x: CGFloat, i: Int)] = []
        var totalW: CGFloat = 0
        var index = 0
        for ch in "たいこウェブ" {
            let s = String(ch)
            var w: CGFloat = 57
            if s == "ェ" { w = 40 }
            letters.append((s, totalW + w / 2, index))
            if s != " " { index += 1 }
            totalW += w
        }

        let W: CGFloat = 1170, H: CGFloat = 390
        let darkRed = UIColor(hexString: "#3f0406"), brown = UIColor(hexString: "#7c361e")
        let g1 = gradient("#a41f1e", "#a86a29"), g2 = gradient("#d80e11", "#e08f19")
        let font = Fonts.tntFont(55)

        return Gfx.renderer(CGSize(width: W, height: H), scale: 2).image { rc in
            let c = rc.cgContext
            c.setLineJoin(.round)
            c.setMiterLimit(1)

            func strokeSym(_ s: Sym, _ color: UIColor, _ lw: CGFloat, dy: CGFloat = 0) {
                c.saveGState()
                c.scaleBy(x: s.scale ? 2.8 : 3.2, y: 3.2)
                c.translateBy(x: s.x, y: s.y + dy)
                c.setStrokeColor(color.cgColor); c.setLineWidth(lw)
                c.addPath(s.path); c.strokePath()
                c.restoreGState()
            }
            func gradFill(_ s: Sym, _ g: CGGradient, shade: Bool) {
                c.saveGState()
                c.scaleBy(x: s.scale ? 2.8 : 3.2, y: 3.2)
                c.translateBy(x: s.x, y: s.y)
                c.addPath(s.path); c.clip()
                if shade {
                    c.translateBy(x: 3, y: 2)
                    c.addPath(s.shadow ?? s.path); c.clip()
                }
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 55 - s.y), end: CGPoint(x: 0, y: 95 - s.y),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                c.restoreGState()
            }
            func letter(_ s: String, x: CGFloat, y: CGFloat, stroke: UIColor?, lw: CGFloat, fill: UIColor?) {
                let size = (s as NSString).size(withAttributes: [.font: font])
                let pt = CGPoint(x: x - size.width / 2, y: y)
                if let sc = stroke {
                    (s as NSString).draw(at: pt, withAttributes: [.font: font, .strokeColor: sc,
                                                                  .strokeWidth: lw / 55 * 100,
                                                                  .foregroundColor: UIColor.clear])
                }
                if let f = fill { (s as NSString).draw(at: pt, withAttributes: [.font: font, .foregroundColor: f]) }
            }
            func eachLetter(_ f: (String, CGFloat, Int) -> Void) {
                for k in stride(from: letters.count - 1, through: 0, by: -1) {
                    f(letters[k].s, (W - totalW) / 2 + letters[k].x, letters[k].i)
                }
            }

            for s in syms { strokeSym(s, darkRed, 13.5, dy: 4) }
            eachLetter { l, x, _ in letter(l, x: x, y: 315, stroke: darkRed, lw: 18.5, fill: nil) }
            c.setFillColor(darkRed.cgColor); c.fill(CGRect(x: 400, y: 180, width: 30, height: 50))

            for s in syms {
                strokeSym(s, brown, 13.5)
                strokeSym(s, .white, 7.5)
                gradFill(s, g1, shade: false)
                gradFill(s, g2, shade: true)
            }
            c.setFillColor(UIColor.white.cgColor)
            c.fill(CGRect(x: 382, y: 85, width: 30, height: 15))
            c.fill(CGRect(x: 402, y: 145, width: 15, height: 15))

            eachLetter { l, x, _ in letter(l, x: x, y: 305, stroke: brown, lw: 18.5, fill: nil) }
            eachLetter { l, x, i in letter(l, x: x, y: 305, stroke: subtitleColor(i), lw: 9.5, fill: .white) }
        }
    }
}
