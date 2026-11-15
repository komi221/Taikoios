import SpriteKit
import UIKit

struct ResultData {
    var score = 0, good = 0, ok = 0, bad = 0, miss = 0
    var maxCombo = 0, rollHits = 0, total = 0
    var gaugePercent = 0.0
    var cleared = false
}

/// taiko-web gamerules.js 와 같은 판정 범위/게이지 규칙
struct Rules {
    var good: Double, ok: Double, bad: Double
    var gaugeClear: Double
    var course: String

    init(course: String) {
        self.course = course
        let f = 1000.0 / 60.0
        switch course {
        case "easy", "normal": good = 2.5 * f; ok = 6.5 * f; bad = 7.5 * f
        default: good = 1.5 * f; ok = 4.5 * f; bad = 6.5 * f
        }
        switch course {
        case "easy": gaugeClear = 30.0 / 50
        case "normal", "hard": gaugeClear = 35.0 / 50
        default: gaugeClear = 40.0 / 50
        }
    }

    func soul(total: Int) -> (good: Double, ok: Double, bad: Double) {
        let c = Double(max(total, 1))
        var g: Double, o: Double, b: Double
        switch course {
        case "easy":
            g = floor(10000 / c * 1.575); o = floor(g * 0.75); b = ceil(g / -2)
        case "normal":
            g = floor(10000 / c / 0.7); o = floor(g * 0.75); b = ceil(g / -0.75)
        case "hard":
            g = floor(10000 / c * 1.5); o = floor(g * 0.75); b = ceil(g / -0.8)
        default:
            g = floor(10000 / c / 0.7); o = floor(g * 0.5); b = ceil(g * -1.6)
        }
        return (g, o, b)
    }
}

final class GameScene: SKScene {
    var chart: Chart!
    var audio: GameAudio!
    var calMs = 0.0
    var speedScale = 1.0
    var onFinish: ((ResultData) -> Void)?

    // 원본 view.js 와 같은 1280x720 기준 좌표 (y는 위에서 아래로 쓰고 Y()로 변환)
    private let H: CGFloat = 720
    private let slot = CGPoint(x: 413, y: 257)
    private let laneLeft: CGFloat = 332
    private var W: CGFloat { size.width }
    private func Y(_ y: CGFloat) -> CGFloat { H - y }

    private var rules = Rules(course: "oni")
    private var soul = (good: 0.0, ok: 0.0, bad: 0.0)
    private var started = false
    private var finished = false

    private var notes: [Note] = []
    private var judged: [Bool] = []
    private var judgeList: [Int] = []
    private var judgePtr = 0
    private var rollList: [Int] = []
    private var balloonLeft: [Int: Int] = [:]
    private var doneRolls = Set<Int>()
    private var appear: [Double] = []
    private var spawnOrder: [Int] = []
    private var spawnPtr = 0
    private var nodes: [Int: SKNode] = [:]
    private var endTime = 0.0

    private var res = ResultData()
    private var combo = 0
    private var gauge = 0.0
    private var wasGogo = false

    // 텍스처
    private var texSmallDon = SKTexture(), texSmallKa = SKTexture()
    private var texBigDon = SKTexture(), texBigKa = SKTexture()
    private var texRollSmall = SKTexture(), texRollBig = SKTexture()
    private var texBalloonHead = SKTexture()
    private var texHit: [SKTexture] = []

    // 노드
    private var dancer: DonDancer!
    private var scoreLabel = SKLabelNode()
    private var comboLabel = SKLabelNode()
    private var comboText = SKLabelNode()
    private var gaugeTicks: [SKSpriteNode] = []
    private var hitFx = SKSpriteNode()
    private var drumKeys: [SKSpriteNode] = []
    private var drumImg = SKSpriteNode()
    private var drumBaseY: CGFloat = 0
    private var flashDon = SKSpriteNode(), flashKa = SKSpriteNode()
    private var songA = SKSpriteNode(), songB = SKSpriteNode()

    // 터치 드럼 (원본 touchDrum / touchCircle)
    private var touchDrum = CGRect.zero
    private var touchCircle = (cx: CGFloat(0), cy: CGFloat(0), rx: CGFloat(1), ry: CGFloat(1))

    // MARK: 시계 (오디오 시작 시각 기준, 출력 지연 보정)

    private func songMs(_ uptime: Double) -> Double {
        (uptime - audio.startUptime) * 1000 - audio.latencyMs - calMs
    }
    private func nowMs() -> Double { songMs(ProcessInfo.processInfo.systemUptime) }
    /// 원본 msToPos: speed(=bpm*scroll/60) / 4 px/ms
    private func pxPerMs(_ n: Note) -> Double { max(abs(n.speed), 1) / 240.0 * speedScale }

    // MARK: 구성

    override func didMove(to view: SKView) {
        backgroundColor = .black
        notes = chart.notes
        rules = Rules(course: chart.course)
        soul = rules.soul(total: chart.total)
        res.total = chart.total
        buildScene()
        prepareChart()
        audio.start()
        started = true
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: UIColor, z: CGFloat) -> SKSpriteNode {
        let s = SKSpriteNode(color: color, size: CGSize(width: w, height: h))
        s.anchorPoint = CGPoint(x: 0, y: 1)
        s.position = CGPoint(x: x, y: Y(y))
        s.zPosition = z
        addChild(s)
        return s
    }

    private func sprite(_ tex: SKTexture, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, z: CGFloat) -> SKSpriteNode {
        let s = SKSpriteNode(texture: tex, size: CGSize(width: w, height: h))
        s.anchorPoint = CGPoint(x: 0, y: 1)
        s.position = CGPoint(x: x, y: Y(y))
        s.zPosition = z
        addChild(s)
        return s
    }

    private func coverTexture(_ name: String, height: CGFloat) -> (SKTexture, CGSize) {
        // 가로를 화면 폭에 맞추고 세로는 가운데를 잘라 height만 보이게 (CSS cover/center)
        guard let im = Gfx.image(name) else { return (SKTexture(), CGSize(width: W, height: height)) }
        let fullH = W * im.size.height / im.size.width
        let frac = min(1, height / fullH)
        let base = SKTexture(image: im)
        let t = SKTexture(rect: CGRect(x: 0, y: (1 - frac) / 2, width: 1, height: frac), in: base)
        return (t, CGSize(width: W, height: min(height, fullH)))
    }

    private func buildScene() {
        let bgId = Int.random(in: 1...5)

        // 배경 (곡 배경 a/b 레이어)
        let (ta, sa) = coverTexture("bg_song_\(bgId)a", height: 360)
        songA = sprite(ta, 0, 0, sa.width, sa.height, z: 1)
        let (tb, sb) = coverTexture("bg_song_\(bgId)b", height: 360)
        songB = sprite(tb, 0, 0, sb.width, sb.height, z: 1.1)
        songB.blendMode = .screen
        songB.run(.repeatForever(.sequence([.fadeAlpha(to: 0.15, duration: 0.5), .fadeAlpha(to: 0.8, duration: 0.5)])))

        // 돈쨩
        dancer = DonDancer(beatMs: chart.beatMs)
        dancer.node.position = CGPoint(x: 0, y: Y(0)); dancer.node.zPosition = 1.5
        addChild(dancer.node)

        // 프레임 / 노트 바
        _ = rect(0, 184, W, 176, .black, z: 2)
        _ = rect(328, 158, W - 328, 34, .black, z: 2)
        _ = rect(laneLeft, 192, W - laneLeft, 130, UIColor(hexString: "#2c2a2c"), z: 2.1)
        _ = rect(laneLeft, 326, W - laneLeft, 26, UIColor(hexString: "#847f84"), z: 2.1)

        // 슬롯 (판정 원)
        let slotNode = SKNode(); slotNode.position = CGPoint(x: slot.x, y: Y(slot.y)); slotNode.zPosition = 2.5
        slotNode.alpha = 0.8; addChild(slotNode)
        func ring(_ r: CGFloat, fill: UIColor?, stroke: UIColor?, lw: CGFloat) {
            let c = SKShapeNode(circleOfRadius: r)
            if let f = fill { c.fillColor = f; c.lineWidth = 0 } else { c.fillColor = .clear }
            if let s = stroke { c.strokeColor = s; c.lineWidth = lw }
            slotNode.addChild(c)
        }
        ring(26, fill: UIColor(hexString: "#444544"), stroke: nil, lw: 0)
        ring(33.5, fill: nil, stroke: UIColor(hexString: "#9c9e9c"), lw: 3)
        ring(51.5, fill: nil, stroke: UIColor(hexString: "#5d5e5d"), lw: 3.5)

        // 키 입력 시 노트 바 번쩍임
        flashDon = SKSpriteNode(texture: gradientTexture(UIColor(red: 1, green: 0.35, blue: 0.2, alpha: 1)),
                                size: CGSize(width: W - laneLeft, height: 130))
        flashKa = SKSpriteNode(texture: gradientTexture(UIColor(red: 0.3, green: 0.85, blue: 0.85, alpha: 1)),
                               size: CGSize(width: W - laneLeft, height: 130))
        for f in [flashDon, flashKa] {
            f.anchorPoint = CGPoint(x: 0, y: 0.5); f.position = CGPoint(x: laneLeft, y: Y(257))
            f.zPosition = 2.6; f.alpha = 0; f.blendMode = .add; addChild(f)
        }

        // 노트 텍스처
        let red = UIColor(hexString: "#f34728"), teal = UIColor(hexString: "#65bdbb"), yellow = UIColor(hexString: "#f3b500")
        texSmallDon = noteTexture(red, sheet: "notes", face: 0, radius: 35)
        texSmallKa = noteTexture(teal, sheet: "notes", face: 0, radius: 35)
        texBigDon = noteTexture(red, sheet: "notes", face: 3, radius: 53)
        texBigKa = noteTexture(teal, sheet: "notes", face: 3, radius: 53)
        texRollSmall = noteTexture(yellow, sheet: "notes_drumroll", face: 0, radius: 35)
        texRollBig = noteTexture(yellow, sheet: "notes_drumroll", face: 3, radius: 53)
        texBalloonHead = noteTexture(UIColor(hexString: "#f87700"), sheet: "notes", face: 0, radius: 35)
        texHit = (0..<4).map { Gfx.crop("notes_hit", CGRect(x: 0, y: 128 * CGFloat($0), width: 128, height: 128)) }

        // 히트 이펙트
        hitFx = SKSpriteNode(texture: texHit[1], size: CGSize(width: 128, height: 128))
        hitFx.position = CGPoint(x: slot.x, y: Y(slot.y)); hitFx.zPosition = 3.5; hitFx.alpha = 0
        addChild(hitFx)

        // 왼쪽 패널
        _ = rect(0, 192, 328, 160, UIColor(hexString: "#fa4529"), z: 4)
        if let pat = Gfx.image("bg_score_p1") {
            let crop = SKCropNode()
            let mask = SKSpriteNode(color: .white, size: CGSize(width: 328, height: 160))
            mask.anchorPoint = CGPoint(x: 0, y: 1)
            crop.maskNode = mask
            crop.position = CGPoint(x: 0, y: Y(192)); crop.zPosition = 4.1
            let ps = SKSpriteNode(texture: SKTexture(image: pat), size: CGSize(width: pat.size.width * 1.55, height: pat.size.height * 1.55))
            ps.anchorPoint = CGPoint(x: 0, y: 1); ps.position = CGPoint(x: 0, y: -45 + 0); ps.alpha = 0.5
            crop.addChild(ps)
            let ps2 = SKSpriteNode(texture: SKTexture(image: pat), size: ps.size)
            ps2.anchorPoint = CGPoint(x: 0, y: 1); ps2.position = CGPoint(x: ps.size.width, y: -45); ps2.alpha = 0.5
            crop.addChild(ps2)
            addChild(crop)
        }
        _ = rect(0, 191, 176, 41, .black, z: 4.2)

        // 난이도 아이콘 + 글자
        let diffIdx = ["easy": 0, "normal": 1, "hard": 2, "oni": 3, "ura": 4][chart.course] ?? 3
        _ = sprite(Gfx.crop("difficulty", CGRect(x: 0, y: 144 * CGFloat(diffIdx), width: 168, height: 143)), 16, 232, 141, 120, z: 4.3)
        let diffNames = ["easy": "かんたん", "normal": "ふつう", "hard": "むずかしい", "oni": "おに", "ura": "おに"]
        let dl = SKLabelNode()
        dl.attributedText = strokedText(diffNames[chart.course] ?? "おに", font: Fonts.tntFont(20), width: 7)
        dl.verticalAlignmentMode = .bottom; dl.position = CGPoint(x: 87, y: Y(348)); dl.zPosition = 4.4
        addChild(dl)

        // 점수
        scoreLabel.fontName = Fonts.tnt; scoreLabel.fontSize = 30; scoreLabel.fontColor = .white
        scoreLabel.horizontalAlignmentMode = .right; scoreLabel.verticalAlignmentMode = .top
        scoreLabel.position = CGPoint(x: 155, y: Y(193)); scoreLabel.xScale = 0.7; scoreLabel.zPosition = 4.5
        scoreLabel.text = "0"; addChild(scoreLabel)

        // 태고 북 + 눌림
        _ = sprite(Gfx.crop("taiko", CGRect(x: 0, y: 0, width: 138, height: 162)), 179, 190, 138, 162, z: 5)
        for i in 0..<4 {
            let k = sprite(Gfx.crop("taiko", CGRect(x: 0, y: 162 * CGFloat(i + 1), width: 138, height: 162)), 179, 190, 138, 162, z: 5.1)
            k.alpha = 0; drumKeys.append(k)
        }

        // 콤보 (북 위)
        comboLabel.position = CGPoint(x: 179 + 69, y: Y(190 + 162 * 0.09 + 32)); comboLabel.zPosition = 5.5
        comboLabel.verticalAlignmentMode = .center; comboLabel.isHidden = true; addChild(comboLabel)
        comboText.attributedText = strokedText("コンボ", font: Fonts.tntFont(24), width: 7)
        comboText.verticalAlignmentMode = .center
        comboText.position = CGPoint(x: 248, y: Y(190 + 162 * 0.63 - 8)); comboText.zPosition = 5.5
        comboText.isHidden = true; addChild(comboText)

        // 게이지
        let gx0 = W - 640
        let gbg = rect(gx0 - 8, 126, 600, 34, UIColor(white: 0.1, alpha: 0.85), z: 6)
        gbg.alpha = 0.95
        for i in 0..<50 {
            let t = rect(gx0 + CGFloat(i) * 11.4, 132, 10, 22, UIColor(hexString: "#3b3b3b"), z: 6.1)
            gaugeTicks.append(t)
        }
        let soulBg = SKShapeNode(circleOfRadius: 22)
        soulBg.fillColor = .white; soulBg.strokeColor = .black; soulBg.lineWidth = 3
        soulBg.position = CGPoint(x: W - 57, y: Y(165)); soulBg.zPosition = 6.2; addChild(soulBg)
        let soulT = SKLabelNode(attributedText: strokedText("魂", font: Fonts.kozukaFont(24), fill: UIColor(hexString: "#ff5a2b"), stroke: .clear, width: 0))
        soulT.verticalAlignmentMode = .center; soulT.position = soulBg.position; soulT.zPosition = 6.3
        addChild(soulT)

        // 터치 드럼 (원본 치수 그대로)
        let y0: CGFloat = 365, pad: CGFloat = 13
        let maxH = H - y0
        var h = maxH - pad, w = W, x: CGFloat = 0, y = y0
        if w / h >= 842.0 / 340.0 { w = h / 340 * 842; x = (W - w) / 2; y += pad }
        else { h = w / 842 * 340; y = y + (maxH - h) }
        touchDrum = CGRect(x: x, y: y, width: w, height: h)
        touchCircle = (cx: W / 2, cy: H + h * 0.1, rx: w / 2 - h * 0.03, ry: h * 1.07)
        drumImg = sprite(Gfx.crop("touch_drum", CGRect(x: 0, y: 0, width: 842, height: 340)), x, y, w, h, z: 2)
        drumBaseY = drumImg.position.y
    }

    private func gradientTexture(_ c: UIColor) -> SKTexture {
        let img = Gfx.renderer(CGSize(width: 256, height: 4)).image { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 256, y: 0), options: [])
        }
        return SKTexture(image: img)
    }

    /// 원본 drawCircle: 색 원 + notes.png 얼굴 스프라이트
    private func noteTexture(_ fill: UIColor, sheet: String, face: Int, radius: CGFloat) -> SKTexture {
        let drawSize = face < 2 ? radius * 53.0 / 35.0 : radius
        let d = drawSize * 2 + 8
        let faceImg = Gfx.cropImage(sheet, CGRect(x: 0, y: 172 * face, width: 172, height: 172))
        let img = Gfx.renderer(CGSize(width: d, height: d), scale: 2).image { ctx in
            fill.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: d / 2 - (radius - 1), y: d / 2 - (radius - 1),
                                                 width: (radius - 1) * 2, height: (radius - 1) * 2))
            faceImg?.draw(in: CGRect(x: 0, y: 0, width: d, height: d))
        }
        return SKTexture(image: img)
    }

    private func prepareChart() {
        for (i, n) in notes.enumerated() {
            if (1...4).contains(n.type) { judgeList.append(i) }
            if n.type >= 5 { rollList.append(i) }
            if n.type == 7 { balloonLeft[i] = max(n.balloon, 1) }
        }
        judged = Array(repeating: false, count: notes.count)
        let span = Double(W + 120 - slot.x)
        appear = notes.map { $0.time - span / pxPerMs($0) }
        spawnOrder = Array(notes.indices).sorted { appear[$0] < appear[$1] }
        endTime = notes.map { max($0.time, $0.endTime) }.max() ?? 0
    }

    private func spawn(_ i: Int) {
        let n = notes[i]
        let node: SKNode
        switch n.type {
        case 0:
            node = SKSpriteNode(color: UIColor(hexString: "#bdbdbd"), size: CGSize(width: 3, height: 130))
        case 1: node = SKSpriteNode(texture: texSmallDon)
        case 2: node = SKSpriteNode(texture: texSmallKa)
        case 3: node = SKSpriteNode(texture: texBigDon)
        case 4: node = SKSpriteNode(texture: texBigKa)
        case 5, 6:
            let big = n.type == 6
            let r: CGFloat = big ? 53 : 35
            let endX = CGFloat((n.endTime - n.time) * pxPerMs(n))
            let c = SKNode()
            let s = r - 1.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: s))
            path.addLine(to: CGPoint(x: endX, y: s))
            path.addArc(center: CGPoint(x: endX, y: 0), radius: s, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: 0, y: -s))
            path.closeSubpath()
            let body = SKShapeNode(path: path)
            body.fillColor = UIColor(hexString: "#f3b500"); body.strokeColor = .black; body.lineWidth = 3
            c.addChild(body)
            let head = SKSpriteNode(texture: big ? texRollBig : texRollSmall)
            head.zPosition = 1
            c.addChild(head)
            node = c
        default:
            let c = SKNode()
            let head = SKSpriteNode(texture: texBalloonHead)
            c.addChild(head)
            if let bimg = Gfx.image("balloon") {
                let h = 35.0 * 2 * 1.8 / 2   // size * 1.8
                let b = SKSpriteNode(texture: SKTexture(image: bimg), size: CGSize(width: h / 61 * 115, height: h))
                b.anchorPoint = CGPoint(x: 0, y: 0.5); b.position = CGPoint(x: 35 - 4, y: -2)
                c.addChild(b)
                let l = SKLabelNode()
                l.name = "cnt"
                l.attributedText = strokedText("\(balloonLeft[i] ?? n.balloon)", font: Fonts.tntFont(22), width: 5)
                l.verticalAlignmentMode = .center
                l.position = CGPoint(x: 35 - 4 + b.size.width * 0.45, y: -2)
                c.addChild(l)
            }
            node = c
        }
        node.position = CGPoint(x: W + 120, y: Y(slot.y))
        node.zPosition = n.type == 0 ? 2.8 : 3
        addChild(node)
        nodes[i] = node
    }

    private func removeNode(_ i: Int) { nodes[i]?.removeFromParent(); nodes[i] = nil }

    // MARK: 프레임 업데이트

    override func update(_ currentTime: TimeInterval) {
        guard started, !finished else { return }
        let t = nowMs()

        while spawnPtr < spawnOrder.count && appear[spawnOrder[spawnPtr]] <= t {
            spawn(spawnOrder[spawnPtr]); spawnPtr += 1
        }

        var gone: [Int] = []
        for (i, node) in nodes {
            let n = notes[i]
            let pps = pxPerMs(n)
            var x = slot.x + CGFloat((n.time - t) * pps)
            if n.type == 7 && t >= n.time && t <= n.endTime { x = slot.x }
            node.position.x = x
            if n.type == 7 && t > n.endTime { gone.append(i); continue }
            let right = (n.type == 5 || n.type == 6) ? x + CGFloat((n.endTime - n.time) * pps) : x
            if right < laneLeft - 120 { gone.append(i) }
        }
        gone.forEach { removeNode($0) }

        while judgePtr < judgeList.count {
            let ni = judgeList[judgePtr]
            if judged[ni] { judgePtr += 1; continue }
            if notes[ni].time + rules.bad < t {
                judged[ni] = true; judgePtr += 1
                combo = 0; res.miss += 1; addGauge(soul.bad); refreshHUD()
            } else { break }
        }

        let gogo = chart.gogo.contains { t >= $0.0 && t < $0.1 }
        if gogo && !wasGogo { dancer.trigger("gogostart", at: t, beats: 1.5) }
        wasGogo = gogo
        dancer.update(t: t, gogo: gogo, cleared: gauge / 10000 >= rules.gaugeClear)

        if t > endTime + 1500 { finish() }
    }

    // MARK: 입력 (원본 ontouch 와 같은 판별: 북 중앙 타원 안 = 돈, 밖 = 카, 좌우는 화면 절반)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard started, !finished else { return }
        for touch in touches {
            let p = touch.location(in: self)
            let px = p.x, py = H - p.y
            let c = touchCircle
            let dx = (px - c.cx) / c.rx, dy = (py - c.cy) / c.ry
            let isDon = py <= c.cy && dx * dx + dy * dy <= 1
            hit(isDon: isDon, left: px < W / 2, uptime: touch.timestamp)
        }
    }

    private func hit(isDon: Bool, left: Bool, uptime: Double) {
        audio.playSfx(don: isDon)
        let keyIdx = isDon ? (left ? 2 : 3) : (left ? 0 : 1)
        drumKeys[keyIdx].removeAllActions()
        drumKeys[keyIdx].alpha = 1
        drumKeys[keyIdx].run(.sequence([.wait(forDuration: 0.07), .fadeOut(withDuration: 0.06)]))
        drumImg.removeAllActions()
        drumImg.position.y = drumBaseY - 7
        drumImg.run(.sequence([.wait(forDuration: 0.1), .run { [weak self] in
            guard let s = self else { return }; s.drumImg.position.y = s.drumBaseY }]))
        let flash = isDon ? flashDon : flashKa
        flash.removeAllActions(); flash.alpha = 0.35; flash.run(.fadeOut(withDuration: 0.13))

        let t = songMs(uptime)

        for ri in rollList where !doneRolls.contains(ri) {
            let n = notes[ri]
            guard t >= n.time - 10 && t <= n.endTime else { continue }
            res.rollHits += 1
            if n.type == 7 {
                let left = (balloonLeft[ri] ?? 1) - 1
                balloonLeft[ri] = left
                res.score += 300
                if left <= 0 {
                    doneRolls.insert(ri); res.score += 5000; removeNode(ri)
                } else if let l = nodes[ri]?.childNode(withName: "cnt") as? SKLabelNode {
                    l.attributedText = strokedText("\(left)", font: Fonts.tntFont(22), width: 5)
                }
            } else {
                res.score += n.type == 6 ? 600 : 300
            }
            refreshHUD(); return
        }

        while judgePtr < judgeList.count && judged[judgeList[judgePtr]] { judgePtr += 1 }
        guard judgePtr < judgeList.count else { return }
        let ni = judgeList[judgePtr]
        let n = notes[ni]
        let rel = abs(t - n.time)
        if rel >= rules.bad { return }

        judged[ni] = true
        removeNode(ni)
        let noteIsDon = (n.type == 1 || n.type == 3)
        let big = n.type >= 3
        if noteIsDon != isDon {
            applyBad()
        } else if rel < rules.good {
            registerHit(big: big, factor: 1.0); res.good += 1; addGauge(soul.good)
            showHit(good: true, big: big, don: noteIsDon)
        } else if rel < rules.ok {
            registerHit(big: big, factor: 0.5); res.ok += 1; addGauge(soul.ok)
            showHit(good: false, big: big, don: noteIsDon)
        } else {
            applyBad()
        }
        refreshHUD()
    }

    private func showHit(good: Bool, big: Bool, don: Bool) {
        hitFx.texture = texHit[(good ? 1 : 0) + (big ? 2 : 0)]
        hitFx.removeAllActions(); hitFx.alpha = 1
        hitFx.run(.sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.18)]))
        fly(big: big, don: don)
        if combo > 0 && combo % 10 == 0 { dancer.trigger("10combo", at: nowMs(), beats: 1.5) }
        comboLabel.removeAllActions()
        comboLabel.run(.sequence([.scaleY(to: 1.12, duration: 0.03), .scaleY(to: 1, duration: 0.07)]))
    }

    /// 맞춘 노트가 곡선을 그리며 혼 게이지로 날아가는 연출 (원본 animateBezier)
    private func fly(big: Bool, don: Bool) {
        let tex = big ? (don ? texBigDon : texBigKa) : (don ? texSmallDon : texSmallKa)
        let node = SKSpriteNode(texture: tex)
        node.zPosition = 7
        let x1 = slot.x + 14, y1 = slot.y - 29
        let x2 = W - 55, y2: CGFloat = 165
        let w = x2 - x1, h = y1 - y2
        let p0 = CGPoint(x: x1, y: y1), p1 = CGPoint(x: x1 + w / 6, y: y1 - h * 3.5)
        let p2 = CGPoint(x: x2 - w / 3, y: y2 - h * 5), p3 = CGPoint(x: x2, y: y2)
        node.position = CGPoint(x: x1, y: Y(y1))
        addChild(node)
        let dur = 0.5
        node.run(.sequence([
            .customAction(withDuration: dur) { [weak self] n, e in
                guard let self = self else { return }
                let u = CGFloat(e) / CGFloat(dur)
                let v = 1 - u
                let bx = v*v*v*p0.x + 3*v*v*u*p1.x + 3*v*u*u*p2.x + u*u*u*p3.x
                let by = v*v*v*p0.y + 3*v*v*u*p1.y + 3*v*u*u*p2.y + u*u*u*p3.y
                n.position = CGPoint(x: bx, y: self.Y(by))
                n.alpha = u > 0.75 ? 1 - (u - 0.75) / 0.25 : 1
            },
            .removeFromParent()
        ]))
    }

    private func registerHit(big: Bool, factor: Double) {
        combo += 1
        res.maxCombo = max(res.maxCombo, combo)
        let bonus = Double(min(combo / 10, 10) * 100)
        res.score += Int((1000 + bonus) * factor) * (big ? 2 : 1)
    }

    private func applyBad() {
        combo = 0; res.bad += 1; addGauge(soul.bad)
    }

    private func addGauge(_ v: Double) { gauge = min(max(gauge + v, 0), 10000) }

    private func refreshHUD() {
        scoreLabel.text = "\(res.score)"
        if combo >= 10 {
            let orange = combo >= 100
            comboLabel.attributedText = strokedText("\(combo)", font: Fonts.tntFont(62),
                                                    fill: orange ? UIColor(hexString: "#ffb521") : .white, width: 7)
            comboText.attributedText = strokedText("コンボ", font: Fonts.tntFont(24),
                                                   fill: orange ? UIColor(hexString: "#ffb521") : .white, width: 7)
            comboLabel.isHidden = false; comboText.isHidden = false
        } else {
            comboLabel.isHidden = true; comboText.isHidden = true
        }
        let filled = Int(gauge / 10000 * 50)
        let clearIdx = Int(rules.gaugeClear * 50)
        for (i, t) in gaugeTicks.enumerated() {
            if i < filled { t.color = i >= clearIdx ? UIColor(hexString: "#ffe400") : UIColor(hexString: "#f58c00") }
            else { t.color = UIColor(hexString: "#3b3b3b") }
        }
    }

    // MARK: 종료

    func abort() {
        guard !finished else { return }
        finished = true
        audio.stop()
    }

    private func finish() {
        finished = true
        audio.stop()
        res.gaugePercent = gauge / 10000
        res.cleared = res.gaugePercent >= rules.gaugeClear
        onFinish?(res)
    }
}
