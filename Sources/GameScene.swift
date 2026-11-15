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

    private var rules = Rules(course: "oni")
    private var soul = (good: 0.0, ok: 0.0, bad: 0.0)
    private var judgeX: CGFloat = 0
    private var laneY: CGFloat = 0
    private var laneH: CGFloat = 0
    private var padTop: CGFloat = 0
    private var beatPx = 0.0
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

    private var pads: [SKSpriteNode] = []
    private let scoreLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private let comboLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let judgeLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private var gaugeFill = SKSpriteNode()
    private var gaugeW: CGFloat = 0

    private var texDon = SKTexture(), texKa = SKTexture()
    private var texBigDon = SKTexture(), texBigKa = SKTexture(), texBalloon = SKTexture()
    private var noteR: CGFloat = 20

    // MARK: 시계 (오디오 시작 시각 기준, 출력 지연 보정)

    private func songMs(_ uptime: Double) -> Double {
        (uptime - audio.startUptime) * 1000 - audio.latencyMs - calMs
    }
    private func nowMs() -> Double { songMs(ProcessInfo.processInfo.systemUptime) }
    private func pxPerMs(_ n: Note) -> Double { max(abs(n.speed), 1) / 60000.0 * beatPx }

    // MARK: 구성

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        notes = chart.notes
        rules = Rules(course: chart.course)
        soul = rules.soul(total: chart.total)
        res.total = chart.total
        buildLayout()
        prepareChart()
        audio.start()
        started = true
    }

    private func buildLayout() {
        let w = size.width, h = size.height
        judgeX = w * 0.22
        laneH = h * 0.28
        laneY = h * 0.70
        padTop = laneY - laneH / 2 - 6
        noteR = laneH * 0.30
        beatPx = Double(w - judgeX) * 0.9 / 4.0 * speedScale

        let lane = SKSpriteNode(color: SKColor(white: 0.16, alpha: 1), size: CGSize(width: w, height: laneH))
        lane.position = CGPoint(x: w / 2, y: laneY); lane.zPosition = 0; addChild(lane)
        let left = SKSpriteNode(color: SKColor(red: 0.85, green: 0.35, blue: 0.1, alpha: 1),
                                size: CGSize(width: judgeX - noteR * 1.4, height: laneH))
        left.position = CGPoint(x: left.size.width / 2, y: laneY); left.zPosition = 4; addChild(left)

        let ring = SKShapeNode(circleOfRadius: noteR * 1.05)
        ring.strokeColor = .white; ring.lineWidth = 3; ring.fillColor = .clear
        ring.position = CGPoint(x: judgeX, y: laneY); ring.zPosition = 1; addChild(ring)

        // 터치 패드 4개: 카 돈 돈 카
        let padW = w / 4, padH = padTop
        let colors: [SKColor] = [.systemBlue, .systemRed, .systemRed, .systemBlue]
        for c in 0..<4 {
            let p = SKSpriteNode(color: colors[c], size: CGSize(width: padW - 6, height: padH - 6))
            p.position = CGPoint(x: padW * (CGFloat(c) + 0.5), y: padH / 2)
            p.alpha = 0.55; p.zPosition = 1; addChild(p); pads.append(p)
        }

        scoreLabel.fontSize = 26; scoreLabel.horizontalAlignmentMode = .right
        scoreLabel.position = CGPoint(x: w - 20, y: h - 36); scoreLabel.text = "0"; scoreLabel.zPosition = 10
        addChild(scoreLabel)

        comboLabel.fontSize = 40; comboLabel.fontColor = .white
        comboLabel.position = CGPoint(x: left.size.width / 2, y: laneY - 14); comboLabel.zPosition = 6
        addChild(comboLabel)

        judgeLabel.fontSize = 26; judgeLabel.alpha = 0
        judgeLabel.position = CGPoint(x: judgeX, y: laneY - laneH / 2 - 26); judgeLabel.zPosition = 10
        addChild(judgeLabel)

        gaugeW = w * 0.5
        let gbg = SKSpriteNode(color: SKColor(white: 0.25, alpha: 1), size: CGSize(width: gaugeW, height: 12))
        gbg.anchorPoint = CGPoint(x: 0, y: 0.5); gbg.position = CGPoint(x: 70, y: h - 30); gbg.zPosition = 9
        addChild(gbg)
        gaugeFill = SKSpriteNode(color: .systemOrange, size: CGSize(width: 0, height: 12))
        gaugeFill.anchorPoint = CGPoint(x: 0, y: 0.5); gaugeFill.position = gbg.position; gaugeFill.zPosition = 10
        addChild(gaugeFill)
        let mark = SKSpriteNode(color: .white, size: CGSize(width: 2, height: 18))
        mark.position = CGPoint(x: 70 + gaugeW * CGFloat(rules.gaugeClear), y: h - 30); mark.zPosition = 11
        addChild(mark)

        texDon = circleTexture(.systemRed, noteR)
        texKa = circleTexture(.systemTeal, noteR)
        texBigDon = circleTexture(.systemRed, noteR * 1.45)
        texBigKa = circleTexture(.systemTeal, noteR * 1.45)
        texBalloon = circleTexture(.systemOrange, noteR * 1.3)
    }

    private func circleTexture(_ color: UIColor, _ r: CGFloat) -> SKTexture {
        let d = r * 2 + 4
        let img = UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor.black.cgColor); c.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
            c.setFillColor(UIColor.white.cgColor); c.fillEllipse(in: CGRect(x: 2, y: 2, width: d - 4, height: d - 4))
            c.setFillColor(color.cgColor); c.fillEllipse(in: CGRect(x: 6, y: 6, width: d - 12, height: d - 12))
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
        let span = Double(size.width + 100 - judgeX)
        appear = notes.map { $0.time - span / pxPerMs($0) }
        spawnOrder = Array(notes.indices).sorted { appear[$0] < appear[$1] }
        endTime = notes.map { max($0.time, $0.endTime) }.max() ?? 0
    }

    private func spawn(_ i: Int) {
        let n = notes[i]
        let node: SKNode
        switch n.type {
        case 0: node = SKSpriteNode(color: SKColor(white: 1, alpha: 0.5), size: CGSize(width: 2, height: laneH))
        case 1: node = SKSpriteNode(texture: texDon)
        case 2: node = SKSpriteNode(texture: texKa)
        case 3: node = SKSpriteNode(texture: texBigDon)
        case 4: node = SKSpriteNode(texture: texBigKa)
        case 5, 6:
            let len = CGFloat((n.endTime - n.time) * pxPerMs(n))
            let r = n.type == 6 ? noteR * 1.45 : noteR
            let s = SKSpriteNode(color: .systemYellow, size: CGSize(width: max(len, 4), height: r * 1.5))
            s.anchorPoint = CGPoint(x: 0, y: 0.5); node = s
        default:
            let s = SKSpriteNode(texture: texBalloon)
            let l = SKLabelNode(fontNamed: "AvenirNext-Bold")
            l.name = "cnt"; l.fontSize = 18; l.fontColor = .black; l.verticalAlignmentMode = .center
            l.text = "\(balloonLeft[i] ?? n.balloon)"; s.addChild(l); node = s
        }
        node.position = CGPoint(x: size.width + 100, y: laneY)
        node.zPosition = n.type == 0 ? 2 : (n.type >= 5 && n.type <= 6 ? 3 : 5)
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
            var x = judgeX + CGFloat((n.time - t) * pps)
            if n.type == 7 && t >= n.time && t <= n.endTime { x = judgeX }
            node.position.x = x
            if n.type == 7 && t > n.endTime { gone.append(i); continue }
            let right = n.type >= 5 && n.type <= 6 ? x + CGFloat((n.endTime - n.time) * pps) : x
            if right < -140 { gone.append(i) }
        }
        gone.forEach { removeNode($0) }

        // 놓친 노트
        while judgePtr < judgeList.count {
            let ni = judgeList[judgePtr]
            if judged[ni] { judgePtr += 1; continue }
            if notes[ni].time + rules.bad < t {
                judged[ni] = true; judgePtr += 1
                combo = 0; res.miss += 1; addGauge(soul.bad); showJudge("MISS", .gray); refreshHUD()
            } else { break }
        }

        if t > endTime + 1500 { finish() }
    }

    // MARK: 입력

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard started, !finished else { return }
        for touch in touches {
            let p = touch.location(in: self)
            guard p.y < padTop else { continue }
            let col = min(max(Int(p.x / (size.width / 4)), 0), 3)
            hit(col: col, uptime: touch.timestamp)
        }
    }

    private func hit(col: Int, uptime: Double) {
        let isDonHit = (col == 1 || col == 2)
        audio.playSfx(don: isDonHit)
        pads[col].removeAllActions()
        pads[col].alpha = 1
        pads[col].run(.fadeAlpha(to: 0.55, duration: 0.12))
        let t = songMs(uptime)

        // 연타 / 풍선 진행 중
        for ri in rollList where !doneRolls.contains(ri) {
            let n = notes[ri]
            guard t >= n.time - 10 && t <= n.endTime else { continue }
            res.rollHits += 1
            if n.type == 7 {
                let left = (balloonLeft[ri] ?? 1) - 1
                balloonLeft[ri] = left
                res.score += 300
                if left <= 0 {
                    doneRolls.insert(ri); res.score += 5000; removeNode(ri); showJudge("POP!", .orange)
                } else {
                    (nodes[ri]?.childNode(withName: "cnt") as? SKLabelNode)?.text = "\(left)"
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
        if rel >= rules.bad { return }          // 너무 이른 타격은 무시

        judged[ni] = true
        removeNode(ni)
        let noteIsDon = (n.type == 1 || n.type == 3)
        let big = n.type >= 3
        if noteIsDon != isDonHit {
            applyBad()
        } else if rel < rules.good {
            registerHit(big: big, factor: 1.0); res.good += 1; addGauge(soul.good); showJudge("GOOD", .yellow)
        } else if rel < rules.ok {
            registerHit(big: big, factor: 0.5); res.ok += 1; addGauge(soul.ok); showJudge("OK", .white)
        } else {
            applyBad()
        }
        refreshHUD()
    }

    private func registerHit(big: Bool, factor: Double) {
        combo += 1
        res.maxCombo = max(res.maxCombo, combo)
        let bonus = Double(min(combo / 10, 10) * 100)
        res.score += Int((1000 + bonus) * factor) * (big ? 2 : 1)
    }

    private func applyBad() {
        combo = 0; res.bad += 1; addGauge(soul.bad); showJudge("BAD", .systemRed)
    }

    private func addGauge(_ v: Double) { gauge = min(max(gauge + v, 0), 10000) }

    private func showJudge(_ text: String, _ color: UIColor) {
        judgeLabel.removeAllActions()
        judgeLabel.text = text; judgeLabel.fontColor = color; judgeLabel.alpha = 1
        judgeLabel.run(.sequence([.wait(forDuration: 0.25), .fadeOut(withDuration: 0.2)]))
    }

    private func refreshHUD() {
        scoreLabel.text = "\(res.score)"
        comboLabel.text = combo >= 2 ? "\(combo)" : ""
        gaugeFill.size.width = gaugeW * CGFloat(gauge / 10000)
        gaugeFill.color = gauge / 10000 >= rules.gaugeClear ? .systemYellow : .systemOrange
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
