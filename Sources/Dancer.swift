import SpriteKit
import UIKit

/// 원본 view.js의 돈쨩 애니메이션 (a / b1 / b2 시트를 몸·얼굴 색으로 합성)
final class DonDancer {
    let node = SKSpriteNode()
    private var sheets: [String: SKTexture] = [:]
    private var sheetSize: [String: CGSize] = [:]
    private var frameCache: [String: SKTexture] = [:]
    private var oneShot: (name: String, start: Double, beats: Double)?
    private var lastKey = ""
    private let beatMs: Double

    static let normalSeq: [Int] = [
        0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 6, 5, 4, 3, 2, 1,
        0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 6, 5, 4, 3, 2, 1,
        0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 6, 5, 7, 8, 9, 10,
        11, 11, 11, 11, 10, 9, 8, 7, 13, 12, 12, 13, 14, 15, 16, 17
    ]
    static let gogoSeq: [Int] = [
        42, 43, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54,
        55, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13,
        14, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
        27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41
    ]

    init(beatMs: Double, body: UIColor = UIColor(hexString: "#5fb7c1"), face: UIColor = UIColor(hexString: "#ff5724")) {
        self.beatMs = max(beatMs, 100)
        node.anchorPoint = CGPoint(x: 0, y: 1)
        node.size = CGSize(width: 361, height: 184.5)
        for name in ["normal", "10combo", "gogo", "gogostart", "clear"] {
            if let img = Self.compose("don_anim_" + name, body: body, face: face) {
                sheets[name] = SKTexture(image: img)
                sheetSize[name] = img.size
            }
        }
    }

    private static func tinted(_ img: UIImage, _ color: UIColor) -> UIImage {
        Gfx.renderer(img.size).image { ctx in
            let rect = CGRect(origin: .zero, size: img.size)
            color.setFill()
            ctx.fill(rect)
            img.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }
    }

    private static func compose(_ base: String, body: UIColor, face: UIColor) -> UIImage? {
        guard let a = Gfx.image(base + "_a") else { return nil }
        let b1 = Gfx.image(base + "_b1"), b2 = Gfx.image(base + "_b2")
        return Gfx.renderer(a.size).image { _ in
            let rect = CGRect(origin: .zero, size: a.size)
            if let b2 = b2 { tinted(b2, face).draw(in: rect) }
            if let b1 = b1 { tinted(b1, body).draw(in: rect) }
            a.draw(in: rect)
        }
    }

    /// 처음 쓰는 순간 GPU 업로드로 끊기지 않도록 미리 올릴 시트 텍스처
    var sheetTextures: [SKTexture] { Array(sheets.values) }

    func trigger(_ name: String, at t: Double, beats: Double) {
        oneShot = (name, t, beats)
    }

    func update(t: Double, gogo: Bool, cleared: Bool) {
        var name = "normal"
        var beats = 4.0
        var start = 0.0
        if let o = oneShot {
            if t >= o.start + o.beats * beatMs { oneShot = nil }
            else { name = o.name; beats = o.beats; start = o.start }
        }
        if oneShot == nil {
            if gogo { name = "gogo" } else if cleared { name = "clear"; beats = 2 }
        }
        let seq: [Int]
        switch name {
        case "normal": seq = Self.normalSeq
        case "gogo": seq = Self.gogoSeq
        case "10combo": seq = Array(0..<22)
        case "gogostart": seq = Array(0..<27)
        default: seq = Array(0..<30)
        }
        let per = beats * beatMs / Double(seq.count)
        var idx = Int(floor((t - start) / per))
        idx = ((idx % seq.count) + seq.count) % seq.count
        let frame = seq[idx]
        let key = "\(name)-\(frame)"
        if key == lastKey { return }
        lastKey = key
        if let tex = frameTexture(name, frame, key) { node.texture = tex }
    }

    private func frameTexture(_ name: String, _ frame: Int, _ key: String) -> SKTexture? {
        if let c = frameCache[key] { return c }
        guard let sheet = sheets[name], let sz = sheetSize[name] else { return nil }
        let x = CGFloat(frame / 10) * 362, y = CGFloat(frame % 10) * 186
        guard x + 360 <= sz.width + 1, y + 184 <= sz.height + 1 else { return nil }
        let t = SKTexture(rect: CGRect(x: x / sz.width, y: 1 - (y + 184) / sz.height,
                                       width: 360 / sz.width, height: 184 / sz.height), in: sheet)
        frameCache[key] = t
        return t
    }
}
