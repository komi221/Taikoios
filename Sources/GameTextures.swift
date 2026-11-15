import SpriteKit
import UIKit

/// 게임 화면에서 쓰는 모든 텍스처를 한 번만 만들어 두는 곳.
/// 게임 중에 텍스트 래스터라이즈/텍스처 생성이 일어나면 그 프레임이 끊기므로 전부 미리 만든다.
final class GameTextures {
    // 노트
    var smallDon = SKTexture(), smallKa = SKTexture(), bigDon = SKTexture(), bigKa = SKTexture()
    var rollSmall = SKTexture(), rollBig = SKTexture(), balloonHead = SKTexture()
    let noteSize = CGSize(width: 114, height: 114)
    var rollMid: [SKTexture] = [], rollCap: [SKTexture] = []      // [small, big]
    // 효과
    var hit: [SKTexture] = []
    var fire: [SKTexture] = []
    var explosion: [[SKTexture]] = []                              // [type][row]
    var judge: [String: SKTexture] = [:]                           // good / ok / bad
    var judgeSize: [String: CGSize] = [:]
    // HUD
    var scoreDigits: [SKTexture] = []
    var comboDigits: [[SKTexture]] = []                            // [white, orange]
    var comboWord: [SKTexture] = []                                // [white, orange]
    var balloonDigits: [SKTexture] = []
    var slotRing = SKTexture()
    var leftPanel = SKTexture()
    var gaugeFrame = SKTexture(), gaugeTicks = SKTexture()
    var clearMark: [SKTexture] = []                                // [off, on]
    var soul: [SKTexture] = []                                     // [off, on]
    var gradDon = SKTexture(), gradKa = SKTexture(), gradYellow = SKTexture(), gradGogo = SKTexture()
    var all: [SKTexture] = []

    // 게이지 치수 (원본 canvasdraw.gauge)
    static let gaugeW: CGFloat = 700
    let gaugeClear: CGFloat

    init(rules: Rules) {
        gaugeClear = Self.gaugeW * CGFloat(rules.gaugeClear - 1.0 / 50)
        buildNotes()
        buildEffects()
        buildDigits()
        buildJudge()
        buildPanels()
        buildGauge(rules: rules)
        all = [smallDon, smallKa, bigDon, bigKa, rollSmall, rollBig, balloonHead]
            + rollMid + rollCap + hit + fire + explosion.flatMap { $0 } + Array(judge.values)
            + scoreDigits + comboDigits.flatMap { $0 } + comboWord + balloonDigits
            + [slotRing, leftPanel, gaugeFrame, gaugeTicks, gradDon, gradKa, gradYellow, gradGogo] + clearMark + soul
    }

    // MARK: 렌더 도우미
    private func tex(_ size: CGSize, scale: CGFloat = 2, _ draw: (CGContext) -> Void) -> SKTexture {
        SKTexture(image: Gfx.renderer(size, scale: scale).image { draw($0.cgContext) })
    }

    private static var vectorTable: [String: String] = {
        guard let u = Bundle.main.url(forResource: "vectors", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }()
    static func vector(_ k: String) -> CGPath { SVGPath.parse(vectorTable[k] ?? "") }

    // MARK: 노트 (원본 drawCircle: 색 원 + 얼굴 스프라이트)
    private func noteTexture(_ fill: UIColor, sheet: String, face: Int, radius: CGFloat) -> SKTexture {
        let drawSize = face < 2 ? radius * 53.0 / 35.0 : radius
        let d = drawSize * 2 + 8
        let faceImg = Gfx.cropImage(sheet, CGRect(x: 0, y: 172 * face, width: 172, height: 172))
        return tex(CGSize(width: d, height: d)) { c in
            fill.setFill()
            c.fillEllipse(in: CGRect(x: d / 2 - (radius - 1), y: d / 2 - (radius - 1),
                                     width: (radius - 1) * 2, height: (radius - 1) * 2))
            faceImg?.draw(in: CGRect(x: 0, y: 0, width: d, height: d))
        }
    }

    private func buildNotes() {
        let red = UIColor(hexString: "#f34728"), teal = UIColor(hexString: "#65bdbb")
        let yellow = UIColor(hexString: "#f3b500"), orange = UIColor(hexString: "#f87700")
        smallDon = noteTexture(red, sheet: "notes", face: 0, radius: 35)
        smallKa = noteTexture(teal, sheet: "notes", face: 0, radius: 35)
        bigDon = noteTexture(red, sheet: "notes", face: 3, radius: 53)
        bigKa = noteTexture(teal, sheet: "notes", face: 3, radius: 53)
        rollSmall = noteTexture(yellow, sheet: "notes_drumroll", face: 0, radius: 35)
        rollBig = noteTexture(yellow, sheet: "notes_drumroll", face: 3, radius: 53)
        balloonHead = noteTexture(orange, sheet: "notes", face: 0, radius: 35)

        // 연타 몸통: 가운데 늘어나는 부분 + 오른쪽 둥근 끝 (SKShapeNode 를 매번 만들지 않기 위해 텍스처로)
        for r in [CGFloat(35), CGFloat(53)] {
            let s = r - 1.5
            let yel = UIColor(hexString: "#f3b500")
            rollMid.append(tex(CGSize(width: 4, height: r * 2)) { c in
                yel.setFill(); c.fill(CGRect(x: 0, y: r - s, width: 4, height: s * 2))
                UIColor.black.setFill()
                c.fill(CGRect(x: 0, y: r - s - 1.5, width: 4, height: 3))
                c.fill(CGRect(x: 0, y: r + s - 1.5, width: 4, height: 3))
            })
            rollCap.append(tex(CGSize(width: r + 2, height: r * 2)) { c in
                c.addEllipse(in: CGRect(x: -s, y: r - s, width: s * 2, height: s * 2))
                yel.setFill(); UIColor.black.setStroke(); c.setLineWidth(3)
                c.drawPath(using: .fillStroke)
            })
        }
    }

    // MARK: 히트/불꽃/폭발
    private func buildEffects() {
        hit = (0..<4).map { Gfx.crop("notes_hit", CGRect(x: 0, y: 128 * CGFloat($0), width: 128, height: 128)) }
        fire = (0..<7).map { Gfx.crop("fire_anim", CGRect(x: 360 * CGFloat($0), y: 0, width: 360, height: 370)) }
        explosion = (0..<4).map { t in
            (0..<4).map { r in Gfx.crop("notes_explosion", CGRect(x: 222 * CGFloat(t), y: 222 * CGFloat(r), width: 222, height: 222)) }
        }
        func grad(_ c: UIColor) -> SKTexture {
            tex(CGSize(width: 256, height: 4), scale: 1) { ctx in
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 256, y: 0), options: [])
            }
        }
        gradDon = grad(UIColor(red: 1, green: 0, blue: 0, alpha: 1))          // 원본: rgb(255,0,0)
        gradKa = grad(UIColor(red: 0, green: 170 / 255, blue: 1, alpha: 1))    // rgb(0,170,255)
        gradYellow = grad(UIColor(red: 1, green: 231 / 255, blue: 0, alpha: 1))
        // 고고타임 배경 (원본 drawGogoTime 그라데이션)
        gradGogo = tex(CGSize(width: 512, height: 4), scale: 1) { ctx in
            let cols = [UIColor(red: 1, green: 0, blue: 0, alpha: 0.16), UIColor(red: 1, green: 0, blue: 0, alpha: 0.28),
                        UIColor(red: 1, green: 83 / 255, blue: 157 / 255, alpha: 0.4),
                        UIColor(red: 1, green: 83 / 255, blue: 157 / 255, alpha: 0)].map { $0.cgColor }
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: [0, 0.45, 0.77, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 512, y: 0), options: [])
        }
    }

    // MARK: 숫자
    private func buildDigits() {
        // 점수: TnT 30px 흰색, 칸 폭 29
        let f30 = Fonts.tntFont(30)
        scoreDigits = (0..<10).map { d in
            let s = String(d) as NSString
            return tex(CGSize(width: 29, height: 38), scale: 3) { _ in
                let ts = s.size(withAttributes: [.font: f30])
                s.draw(at: CGPoint(x: (29 - ts.width) / 2, y: (38 - ts.height) / 2),
                       withAttributes: [.font: f30, .foregroundColor: UIColor.white])
            }
        }

        // 콤보: 검은 외곽선 + 그림자 + 흰색(또는 주황 그라데이션) (원본 fillComboCache 근사)
        let f58 = Fonts.tntFont(58)
        let cell = CGSize(width: 54, height: 68)
        for orange in [false, true] {
            var arr: [SKTexture] = []
            for d in 0..<10 {
                let s = String(d) as NSString
                let ts = s.size(withAttributes: [.font: f58])
                let o = CGPoint(x: (cell.width - ts.width) / 2, y: (cell.height - ts.height) / 2)
                // 채움 이미지: 흰색 글자 또는 (그라데이션 ∩ 글자)
                let textMask = Gfx.renderer(cell, scale: 3).image { _ in
                    s.draw(at: o, withAttributes: [.font: f58, .foregroundColor: UIColor.white])
                }
                var fillImg = textMask
                if orange {
                    let gradImg = Gfx.renderer(cell, scale: 3).image { g in
                        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                              colors: [UIColor(hexString: "#ff2000").cgColor, UIColor(hexString: "#ffc321").cgColor,
                                                       UIColor(hexString: "#ffedb7").cgColor, UIColor(hexString: "#ffffce").cgColor] as CFArray,
                                              locations: [0.3, 0.5, 0.6, 0.8])!
                        g.cgContext.drawLinearGradient(grad, start: CGPoint(x: 0, y: 12), end: CGPoint(x: 0, y: 62),
                                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    }
                    fillImg = Gfx.renderer(cell, scale: 3).image { _ in
                        gradImg.draw(at: .zero)
                        textMask.draw(at: .zero, blendMode: .destinationIn, alpha: 1)
                    }
                }
                arr.append(tex(cell, scale: 3) { _ in
                    s.draw(at: o, withAttributes: [.font: f58, .strokeColor: UIColor.black, .strokeWidth: 15,
                                                   .foregroundColor: UIColor.clear])
                    s.draw(at: CGPoint(x: o.x + 2, y: o.y + 1),
                           withAttributes: [.font: f58, .foregroundColor: UIColor(white: 0, alpha: 0.5)])
                    fillImg.draw(at: .zero)
                })
            }
            comboDigits.append(arr)
        }
        // "コンボ"
        let f24 = Fonts.tntFont(24)
        for orange in [false, true] {
            comboWord.append(tex(CGSize(width: 110, height: 40), scale: 3) { _ in
                let s = "コンボ" as NSString
                let ts = s.size(withAttributes: [.font: f24])
                let p = CGPoint(x: (110 - ts.width) / 2, y: (40 - ts.height) / 2)
                s.draw(at: p, withAttributes: [.font: f24, .strokeColor: UIColor.black, .strokeWidth: 28, .foregroundColor: UIColor.clear])
                s.draw(at: p, withAttributes: [.font: f24, .foregroundColor: orange ? UIColor(hexString: "#ffc321") : UIColor.white])
            })
        }
        // 풍선 남은 횟수
        let f22 = Fonts.tntFont(22)
        balloonDigits = (0..<10).map { d in
            let s = String(d) as NSString
            return tex(CGSize(width: 20, height: 30), scale: 3) { _ in
                let ts = s.size(withAttributes: [.font: f22])
                let p = CGPoint(x: (20 - ts.width) / 2, y: (30 - ts.height) / 2)
                s.draw(at: p, withAttributes: [.font: f22, .strokeColor: UIColor.black, .strokeWidth: 22, .foregroundColor: UIColor.clear])
                s.draw(at: p, withAttributes: [.font: f22, .foregroundColor: UIColor.white])
            }
        }
    }

    // MARK: 良 / 可 / 不可 (원본 draw.score: vectors.json 의 good/ok/bad 경로)
    private func buildJudge() {
        let pad: CGFloat = 8
        func make(_ key: String, _ paths: [(CGPath, CGFloat)], colors: [(CGFloat, UIColor)], gradH: CGFloat, width: CGFloat) {
            let size = CGSize(width: width + pad * 2, height: 29 + pad * 2)
            judge[key] = tex(size, scale: 3) { c in
                c.translateBy(x: pad, y: pad)
                for (p, dx) in paths {
                    c.saveGState(); c.translateBy(x: dx, y: 0)
                    c.addPath(p); c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(7); c.setLineJoin(.miter)
                    c.strokePath()
                    c.restoreGState()
                }
                for (p, dx) in paths {
                    c.saveGState(); c.translateBy(x: dx, y: 0)
                    c.addPath(p); c.clip()
                    if colors.count == 1 {
                        c.setFillColor(colors[0].1.cgColor); c.fill(CGRect(x: -10, y: -10, width: 120, height: 60))
                    } else {
                        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                           colors: colors.map { $0.1.cgColor } as CFArray, locations: colors.map { $0.0 })!
                        c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: gradH),
                                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    }
                    c.restoreGState()
                }
            }
            judgeSize[key] = size
        }
        make("good", [(Self.vector("good"), 0)], colors: [(0.3, UIColor(hexString: "#f7fb00")), (0.9, UIColor(hexString: "#ff4900"))], gradH: 29, width: 23)
        make("ok", [(Self.vector("ok"), 0)], colors: [(0, UIColor.white)], gradH: 29, width: 23)
        make("bad", [(Self.vector("bad"), 0), (Self.vector("ok"), 26)],
             colors: [(0.1, UIColor(hexString: "#6B5DFF")), (0.7, UIColor(hexString: "#00AEDE"))], gradH: 27, width: 49)
    }

    // MARK: 패널/슬롯
    private func buildPanels() {
        // 슬롯 (원본 draw.slot: screen 합성 alpha 0.7)
        slotRing = tex(CGSize(width: 120, height: 120)) { c in
            c.translateBy(x: 60, y: 60)
            c.setAlpha(1)
            UIColor(hexString: "#444544").setFill()
            c.fillEllipse(in: CGRect(x: -26, y: -26, width: 52, height: 52))
            c.setLineWidth(3); UIColor(hexString: "#9c9e9c").setStroke()
            c.strokeEllipse(in: CGRect(x: -33.5, y: -33.5, width: 67, height: 67))
            c.setLineWidth(3.5); UIColor(hexString: "#5d5e5d").setStroke()
            c.strokeEllipse(in: CGRect(x: -51.5, y: -51.5, width: 103, height: 103))
        }
        // 왼쪽 패널: 배경색 + 반투명 패턴(1.55배, 세로 45px 이동) 을 한 장으로
        let pat = Gfx.image("bg_score_p1")
        leftPanel = tex(CGSize(width: 328, height: 160)) { c in
            UIColor(hexString: "#fa4529").setFill(); c.fill(CGRect(x: 0, y: 0, width: 328, height: 160))
            guard let p = pat else { return }
            let tw = p.size.width * 1.55, th = p.size.height * 1.55
            c.setAlpha(0.5)
            var y = 45 - ceil(45 / th) * th
            while y < 160 {
                var x: CGFloat = 0
                while x < 328 { p.draw(in: CGRect(x: x, y: y, width: tw, height: th)); x += tw }
                y += th
            }
        }
    }

    // MARK: 게이지 (원본 canvasdraw.gauge / soul)
    private func buildGauge(rules: Rules) {
        let gw = Self.gaugeW, gc = gaugeClear
        let firstTop: CGFloat = 30, secondTop: CGFloat = 8
        let size = CGSize(width: 792, height: 56)
        gaugeFrame = tex(size) { c in
            // 바탕
            UIColor.black.setFill()
            let p = CGMutablePath()
            p.move(to: CGPoint(x: gc - 7, y: 24))
            p.addArc(tangent1End: CGPoint(x: gc - 7, y: 0), tangent2End: CGPoint(x: gc + 11, y: 0), radius: 18)
            p.addLine(to: CGPoint(x: 788, y: 0)); p.addLine(to: CGPoint(x: 788, y: 24)); p.closeSubpath()
            c.addPath(p); c.fillPath()
            UIColor(hexString: "#680000").setFill()
            c.fill(CGRect(x: 0, y: firstTop, width: gc + 2, height: 22))
            UIColor(hexString: "#684900").setFill()
            c.fill(CGRect(x: gc + 9, y: secondTop, width: gw - 4 - (gc + 9), height: 44))
        }
        gaugeTicks = tex(size) { c in
            UIColor(white: 0, alpha: 0.16).setStroke()
            var lw: CGFloat = 5
            c.setLineWidth(lw)
            let clearIdx = Int((rules.gaugeClear * 50).rounded())
            for i in 0..<49 {
                if i == clearIdx - 1 { lw = 4; c.setLineWidth(lw) }
                let x = 14 + CGFloat(i) * 14 - lw / 2
                c.move(to: CGPoint(x: x, y: x < gc ? firstTop : secondTop))
                c.addLine(to: CGPoint(x: x, y: x < gc ? firstTop + 22 : secondTop + 44))
                c.strokePath()
            }
        }
        // 클리어 표시 (기준선 + "クリア" 글자) — 달성 전/후 두 장
        let f18 = Fonts.tntFont(18)
        for cleared in [false, true] {
            clearMark.append(tex(size) { c in
                (cleared ? UIColor(hexString: "#ffff00") : UIColor(hexString: "#684900")).setFill()
                let p = CGMutablePath()
                p.move(to: CGPoint(x: gc, y: secondTop + 44))
                p.addArc(tangent1End: CGPoint(x: gc, y: secondTop), tangent2End: CGPoint(x: gc + 10, y: secondTop), radius: 10)
                p.addLine(to: CGPoint(x: gc + 10, y: secondTop + 44)); p.closeSubpath()
                c.addPath(p); c.fillPath()
                if cleared { UIColor.white.setFill(); c.fill(CGRect(x: gc, y: secondTop, width: 10, height: 3)) }
                let s = "クリア" as NSString
                let pt = CGPoint(x: gc + 3, y: 11)
                s.draw(at: pt, withAttributes: [.font: f18, .strokeColor: UIColor.black, .strokeWidth: 30, .foregroundColor: UIColor.clear, .kern: -2])
                s.draw(at: pt, withAttributes: [.font: f18, .foregroundColor: cleared ? UIColor.white : UIColor(hexString: "#737373"), .kern: -2])
            })
        }
        let soulPath = Self.vector("soul")
        for cleared in [false, true] {
            soul.append(tex(CGSize(width: 50, height: 46)) { c in
                c.addPath(soulPath)
                (cleared ? UIColor.white : UIColor(hexString: "#737373")).setFill()
                c.fillPath()
            })
        }
    }
}
