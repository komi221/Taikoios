import SpriteKit
import UIKit

struct ResultData {
    var score = 0, good = 0, ok = 0, bad = 0, miss = 0
    var maxCombo = 0, rollHits = 0, total = 0
    var gaugePercent = 0.0
    var cleared = false
    // 저장 결과 (ScoreStore)
    var crown = ""            // "", "silver", "gold"
    var isRecord = false
    var best = 0
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

    /// 원본 gaugePercent: 200 단위로 내림
    func gaugePercent(_ gauge: Double) -> Double { floor(gauge / 200) / 50 }
    func clearReached(_ gauge: Double) -> Bool { gaugePercent(gauge) >= gaugeClear }
}

// MARK: 재사용 노드 (노트마다 새 노드를 만들지 않고 풀에서 꺼내 쓴다)

/// 숫자를 스프라이트로 보여주는 노드. 텍스트를 매번 래스터라이즈하지 않고 미리 만든 글자 텍스처만 교체한다.
final class DigitNode: SKNode {
    enum Anchor { case right, center }
    private var sprites: [SKSpriteNode] = []
    private var textures: [SKTexture]
    private let anchor: Anchor
    private var lastValue = -1
    private var lastAdvance: CGFloat = -1

    init(textures: [SKTexture], cell: CGSize, capacity: Int, anchor: Anchor, bottomAligned: Bool = false) {
        self.textures = textures
        self.anchor = anchor
        super.init()
        for _ in 0..<capacity {
            let s = SKSpriteNode(texture: textures.first, size: cell)
            if bottomAligned { s.anchorPoint = CGPoint(x: 0.5, y: 0) }
            s.isHidden = true
            addChild(s)
            sprites.append(s)
        }
    }
    required init?(coder aDecoder: NSCoder) { fatalError() }

    func set(_ value: Int, advance: CGFloat) {
        if value == lastValue && advance == lastAdvance { return }
        lastValue = value; lastAdvance = advance
        let digits = Array(String(max(0, value)).compactMap { $0.wholeNumberValue }.suffix(sprites.count))
        let n = digits.count
        for i in 0..<sprites.count {
            if i < n {
                let sp = sprites[i]
                sp.isHidden = false
                sp.texture = textures[digits[i]]
                let off: CGFloat = anchor == .right ? CGFloat(i - (n - 1)) : CGFloat(i) - CGFloat(n - 1) / 2
                sp.position = CGPoint(x: off * advance, y: 0)
            } else {
                sprites[i].isHidden = true
            }
        }
    }

    /// 글자 텍스처 집합을 바꿀 때(흰색 ↔ 주황) 호출. 다음 set() 에서 다시 배치된다.
    func replaceTextures(_ t: [SKTexture]) {
        textures = t
        lastValue = -1
    }
}

final class RollNode: SKNode {
    let body = SKSpriteNode(), cap = SKSpriteNode(), head = SKSpriteNode()
    override init() {
        super.init()
        body.anchorPoint = CGPoint(x: 0, y: 0.5)
        cap.anchorPoint = CGPoint(x: 0, y: 0.5)
        head.zPosition = 0.0005
        addChild(body); addChild(cap); addChild(head)
    }
    required init?(coder aDecoder: NSCoder) { fatalError() }

    func configure(_ t: GameTextures, big: Bool, endX: CGFloat) {
        let r: CGFloat = big ? 53 : 35
        let k = big ? 1 : 0
        body.texture = t.rollMid[k]
        body.size = CGSize(width: max(endX, 0), height: r * 2)
        cap.texture = t.rollCap[k]
        cap.size = CGSize(width: r + 2, height: r * 2)
        cap.position = CGPoint(x: endX, y: 0)
        head.texture = big ? t.rollBig : t.rollSmall
        head.size = t.noteSize
    }
}

final class BalloonNode: SKNode {
    let head = SKSpriteNode(), bal = SKSpriteNode()
    let count: DigitNode
    init(_ t: GameTextures) {
        count = DigitNode(textures: t.balloonDigits, cell: CGSize(width: 20, height: 30), capacity: 3, anchor: .center)
        super.init()
        head.texture = t.balloonHead; head.size = t.noteSize
        let h: CGFloat = 35 * 1.8
        bal.texture = Gfx.texture("balloon")
        bal.size = CGSize(width: h / 61 * 115, height: h)
        bal.anchorPoint = CGPoint(x: 0, y: 0.5)
        bal.position = CGPoint(x: 35 - 4, y: -2)
        count.position = CGPoint(x: 35 - 4 + bal.size.width * 0.45, y: -2)
        bal.zPosition = 0.0002; count.zPosition = 0.0004
        addChild(head); addChild(bal); addChild(count)
    }
    required init?(coder aDecoder: NSCoder) { fatalError() }
}

// MARK: 게임 화면

final class GameScene: SKScene {
    var chart: Chart!
    var audio: GameAudio!
    var calMs = 0.0
    var speedScale = 1.0
    var autoLatency = true
    var onFinish: ((ResultData) -> Void)?

    // 원본 view.js 와 같은 1280x720 기준 좌표 (y는 위에서 아래로 쓰고 Y()로 변환)
    private let H: CGFloat = 720
    private let slot = CGPoint(x: 413, y: 257)
    private let laneLeft: CGFloat = 332
    private var W: CGFloat = 1280
    private func Y(_ y: CGFloat) -> CGFloat { H - y }

    private var rules = Rules(course: "oni")
    private var soul = (good: 0.0, ok: 0.0, bad: 0.0)
    private var started = false
    private var finished = false
    private var tex: GameTextures!

    // 악보 데이터 (평평한 배열: 프레임마다 구조체/딕셔너리를 건드리지 않기 위해)
    private var nTime: [Double] = [], nEnd: [Double] = [], nPps: [Double] = []
    private var nType: [Int] = [], nBalloon: [Int] = [], nGogo: [Bool] = []
    private var nodeFor: [SKNode?] = []
    private var activePos: [Int] = []
    private var active: [Int] = []
    private var judged: [Bool] = []
    private var judgeList: [Int] = []
    private var judgePtr = 0
    private var rollList: [Int] = []
    private var balloonLeft: [Int: Int] = [:]
    private var doneRolls = Set<Int>()
    private var appear: [Double] = []
    private var spawnOrder: [Int] = []
    private var spawnPtr = 0
    private var endTime = 0.0

    // 노드 풀
    private var poolNote: [SKSpriteNode] = []
    private var poolBar: [SKSpriteNode] = []
    private var poolRoll: [RollNode] = []
    private var poolBalloon: [BalloonNode] = []

    private var res = ResultData()
    private var combo = 0
    private var gauge = 0.0
    private var lastGaugeSig = -1

    // 고고타임
    private var gogoRanges: [(Double, Double)] = []
    private var gogoIdx = 0
    private var wasGogo = false
    private var gogoEventMs = -1e9
    private var gogoStartMs = -1e9, gogoEndMs = -1e9

    // 노드
    private var dancer: DonDancer!
    private var scoreNode: DigitNode!
    private var comboNode: DigitNode!
    private var comboWord = SKSpriteNode()
    private var comboOrange = false
    private var drumKeys: [SKSpriteNode] = []
    private var drumImg = SKSpriteNode()
    private var drumBaseY: CGFloat = 0
    private var flashDon = SKSpriteNode(), flashKa = SKSpriteNode(), flashYellow = SKSpriteNode()
    private var gogoBar = SKSpriteNode()
    private var hitFx = SKSpriteNode()
    private var fire = SKSpriteNode()
    private var explosion = SKSpriteNode()
    private var judgeSprite = SKSpriteNode()
    private var darkBg = SKSpriteNode()
    private var gaugeRed = SKSpriteNode(), gaugeRedTop = SKSpriteNode()
    private var gaugeYel = SKSpriteNode(), gaugeYelTop = SKSpriteNode()
    private var clearMarkSprite = SKSpriteNode(), soulSprite = SKSpriteNode()
    private var lastGaugeCleared = false

    // 상태 (SKAction 대신 시각 기반으로 계산 → 터치할 때 액션을 만들지 않는다)
    private var keyTime = [-1e9, -1e9, -1e9, -1e9]      // ka_l ka_r don_l don_r
    private var lastDonMs = -1e9, lastKaMs = -1e9
    private var touchMs = -1e9
    private var scoreMs = -1e9, scoreType = 0, scoreBig = false     // 마지막 판정 (displayScore)
    private var judgeKey = ""
    private var darkTarget: CGFloat = 0, darkAlpha: CGFloat = 0
    private var exStart = -1e9, exType = 0, exBig = false
    private var extraPreload: [SKTexture] = []
    private var lastFrame = 0.0
    private var lastFireIdx = -1, lastExKey = -1

    private struct Fly { var node: SKSpriteNode; var start: Double }
    private var flies: [Fly] = []
    private var flyPool: [SKSpriteNode] = []

    // 터치 드럼 (원본 touchDrum / touchCircle)
    private var touchDrum = CGRect.zero
    private var touchCircle = (cx: CGFloat(0), cy: CGFloat(0), rx: CGFloat(1), ry: CGFloat(1))

    // MARK: 시계 (오디오 시작 시각 기준, 출력 지연 보정)

    private func songMs(_ uptime: Double) -> Double {
        (uptime - audio.startUptime) * 1000 - (autoLatency ? audio.latencyMs : 0) - calMs
    }
    private func nowMs() -> Double { songMs(ProcessInfo.processInfo.systemUptime) }
    /// 원본 msToPos: speed(=bpm*scroll/60) / 4 px/ms
    private func pxPerMs(_ speed: Double) -> Double { max(abs(speed), 1) / 240.0 * speedScale }

    // MARK: 구성

    override func didMove(to view: SKView) {
        backgroundColor = .black
        W = size.width
        rules = Rules(course: chart.course)
        soul = rules.soul(total: chart.total)
        res.total = chart.total
        tex = GameTextures(rules: rules)
        buildScene()
        prepareChart()
        // 텍스처를 미리 GPU 에 올려 둔다 (처음 쓰는 순간 끊기는 걸 방지) → 끝나면 곡 시작
        SKTexture.preload(tex.all + extraPreload + dancer.sheetTextures) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, !self.finished else { return }
                self.audio.start()
                self.started = true
            }
        }
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
        let base = Gfx.texture(name)
        let t = SKTexture(rect: CGRect(x: 0, y: (1 - frac) / 2, width: 1, height: frac), in: base)
        return (t, CGSize(width: W, height: min(height, fullH)))
    }

    private func buildScene() {
        let bgId = Int.random(in: 1...5)
        let donId = Int.random(in: 1...6)
        let stageId = Int.random(in: 1...3)

        // 곡 배경: 원본 #songbg 는 화면 아래쪽 절반
        for n in ["bg_song_\(bgId)a", "bg_song_\(bgId)b", "bg_stage_\(stageId)", "bg_don_\(donId)a", "bg_don_\(donId)b",
                  "taiko", "difficulty", "touch_drum", "balloon"] { extraPreload.append(Gfx.texture(n)) }
        let (ta, sa) = coverTexture("bg_song_\(bgId)a", height: 360)
        _ = sprite(ta, 0, 360, sa.width, sa.height, z: 1)
        let (tb, sb) = coverTexture("bg_song_\(bgId)b", height: 360)
        let songB = sprite(tb, 0, 360, sb.width, sb.height, z: 1.1)
        songB.blendMode = .screen
        // CSS 키프레임(strobe / pulse)을 SKAction 한 개로 — 터치와 상관없이 계속 도는 단순 액션
        switch bgId {
        case 1, 2, 3:   // strobe 0.4s : 1, 0, 0.66, 0
            songB.run(.repeatForever(.sequence([
                .fadeAlpha(to: 1, duration: 0), .wait(forDuration: 0.1), .fadeAlpha(to: 0, duration: 0), .wait(forDuration: 0.1),
                .fadeAlpha(to: 0.66, duration: 0), .wait(forDuration: 0.1), .fadeAlpha(to: 0, duration: 0), .wait(forDuration: 0.1)])))
        case 4:         // pulse 0.4s
            songB.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0), .wait(forDuration: 0.2),
                                                .fadeAlpha(to: 0, duration: 0), .wait(forDuration: 0.2)])))
        default:        // pulse 1s
            songB.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0), .wait(forDuration: 0.5),
                                                .fadeAlpha(to: 0, duration: 0), .wait(forDuration: 0.5)])))
        }
        // 무대 (맨 아래 44px 타일)
        if let _ = Gfx.image("bg_stage_\(stageId)") {
            let t = Gfx.texture("bg_stage_\(stageId)")
            var x: CGFloat = 0
            while x < W { _ = sprite(t, x, 676, 66, 44, z: 1.9); x += 66 }
        }
        buildDonBg(id: donId)

        // 돈쨩
        dancer = DonDancer(beatMs: chart.beatMs)
        dancer.node.position = CGPoint(x: 0, y: Y(0)); dancer.node.zPosition = 1.5
        addChild(dancer.node)

        // 프레임 / 노트 바
        _ = rect(0, 184, W, 176, .black, z: 2)
        _ = rect(328, 158, W - 328, 34, .black, z: 2)
        _ = rect(laneLeft, 192, W - laneLeft, 130, UIColor(hexString: "#2c2a2c"), z: 2.1)
        _ = rect(laneLeft, 326, W - laneLeft, 26, UIColor(hexString: "#847f84"), z: 2.1)

        // 고고타임 배경 / 키 입력 번쩍임 (원본: 막대 전체에 그라데이션)
        gogoBar = SKSpriteNode(texture: tex.gradGogo, size: CGSize(width: W - laneLeft, height: 130))
        gogoBar.anchorPoint = CGPoint(x: 0, y: 0.5); gogoBar.position = CGPoint(x: laneLeft, y: Y(257))
        gogoBar.zPosition = 2.15; gogoBar.isHidden = true; addChild(gogoBar)
        func flash(_ t: SKTexture) -> SKSpriteNode {
            let f = SKSpriteNode(texture: t, size: CGSize(width: W - laneLeft, height: 130))
            f.anchorPoint = CGPoint(x: 0, y: 0.5); f.position = CGPoint(x: laneLeft, y: Y(257))
            f.zPosition = 2.2; f.alpha = 0; f.blendMode = .add; f.isHidden = true; addChild(f)
            return f
        }
        flashDon = flash(tex.gradDon); flashKa = flash(tex.gradKa); flashYellow = flash(tex.gradYellow)

        // 슬롯 (판정 원) — 한 장짜리 텍스처, screen 합성 alpha 0.7
        let ring = SKSpriteNode(texture: tex.slotRing, size: CGSize(width: 120, height: 120))
        ring.position = CGPoint(x: slot.x, y: Y(slot.y)); ring.zPosition = 2.5
        ring.alpha = 0.7; ring.blendMode = .screen; addChild(ring)

        // 히트 이펙트 / 불꽃 / 폭발 / 判定 글자
        hitFx = SKSpriteNode(texture: tex.hit[1], size: CGSize(width: 128, height: 128))
        hitFx.position = CGPoint(x: slot.x, y: Y(slot.y)); hitFx.zPosition = 2.9; hitFx.isHidden = true
        addChild(hitFx)

        fire = SKSpriteNode(texture: tex.fire[0], size: CGSize(width: 360, height: 370))
        fire.position = CGPoint(x: slot.x, y: Y(slot.y)); fire.zPosition = 2.75
        fire.blendMode = .add; fire.isHidden = true; addChild(fire)

        explosion = SKSpriteNode(texture: tex.explosion[0][0], size: CGSize(width: 222, height: 222))
        explosion.position = CGPoint(x: slot.x, y: Y(slot.y)); explosion.zPosition = 3.6
        explosion.blendMode = .screen; explosion.isHidden = true; addChild(explosion)

        judgeSprite = SKSpriteNode(texture: tex.judge["good"], size: tex.judgeSize["good"] ?? .zero)
        judgeSprite.anchorPoint = CGPoint(x: 0.5, y: 1); judgeSprite.zPosition = 3.7
        judgeSprite.setScale(1.35); judgeSprite.isHidden = true; addChild(judgeSprite)

        // 왼쪽 패널 (한 장)
        _ = sprite(tex.leftPanel, 0, 192, 328, 160, z: 4)
        _ = rect(0, 191, 176, 41, .black, z: 4.2)

        // 난이도 아이콘 + 글자
        let diffIdx = ["easy": 0, "normal": 1, "hard": 2, "oni": 3, "ura": 4][chart.course] ?? 3
        _ = sprite(Gfx.crop("difficulty", CGRect(x: 0, y: 144 * CGFloat(diffIdx), width: 168, height: 143)), 16, 232, 141, 120, z: 4.3)
        let diffNames = ["easy": "かんたん", "normal": "ふつう", "hard": "むずかしい", "oni": "おに", "ura": "おに"]
        let dl = SKLabelNode()
        dl.attributedText = strokedText(diffNames[chart.course] ?? "おに", font: Fonts.tntFont(20), width: 7)
        dl.verticalAlignmentMode = .bottom; dl.position = CGPoint(x: 87, y: Y(348)); dl.zPosition = 4.4
        addChild(dl)

        // 점수: 글자 스프라이트 (원본 TnT 30px, 폭 29, 가로 0.7배)
        scoreNode = DigitNode(textures: tex.scoreDigits, cell: CGSize(width: 29, height: 38), capacity: 9, anchor: .right)
        scoreNode.position = CGPoint(x: 155, y: Y(193 + 19)); scoreNode.xScale = 0.7; scoreNode.zPosition = 4.5
        scoreNode.set(0, advance: 29)
        addChild(scoreNode)

        // 태고 북 + 눌림 (alpha 는 update 에서 시각으로 계산)
        _ = sprite(Gfx.crop("taiko", CGRect(x: 0, y: 0, width: 138, height: 162)), 179, 190, 138, 162, z: 5)
        for i in 0..<4 {
            let k = sprite(Gfx.crop("taiko", CGRect(x: 0, y: 162 * CGFloat(i + 1), width: 138, height: 162)), 179, 190, 138, 162, z: 5.1)
            k.isHidden = true; drumKeys.append(k)
        }

        // 콤보 (북 위)
        comboNode = DigitNode(textures: tex.comboDigits[0], cell: CGSize(width: 54, height: 68), capacity: 5,
                              anchor: .center, bottomAligned: true)
        comboNode.position = CGPoint(x: 248, y: Y(190 + 162 * 0.09 + 65 + 1.5)); comboNode.zPosition = 5.5
        comboNode.isHidden = true; addChild(comboNode)
        comboWord = SKSpriteNode(texture: tex.comboWord[0], size: CGSize(width: 110, height: 40))
        comboWord.position = CGPoint(x: 248, y: Y(190 + 162 * 0.63 - 8)); comboWord.zPosition = 5.5
        comboWord.isHidden = true; addChild(comboWord)

        buildGauge()

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

        // 미스했을 때 돈 배경을 어둡게 (원본 donlayer3: 검정 0.5, 0.15초 전환)
        darkBg = rect(0, 0, W, 184.5, .black, z: 1.3)
        darkBg.alpha = 0
    }

    /// 원본 canvasdraw.gauge / soul 을 스프라이트로 (정적 부분은 텍스처 한 장씩, 채움 부분만 크기 변경)
    private func buildGauge() {
        let gx = W - 788, gy: CGFloat = 135
        let host = SKNode(); host.position = CGPoint(x: gx, y: Y(gy)); host.zPosition = 6; addChild(host)
        func local(_ t: SKTexture, _ w: CGFloat, _ h: CGFloat, z: CGFloat) -> SKSpriteNode {
            let s = SKSpriteNode(texture: t, size: CGSize(width: w, height: h))
            s.anchorPoint = CGPoint(x: 0, y: 1); s.position = .zero; s.zPosition = z; host.addChild(s); return s
        }
        _ = local(tex.gaugeFrame, 792, 56, z: 0)
        func bar(_ c: UIColor, y: CGFloat, h: CGFloat, x: CGFloat, z: CGFloat) -> SKSpriteNode {
            let s = SKSpriteNode(color: c, size: CGSize(width: 0, height: h))
            s.anchorPoint = CGPoint(x: 0, y: 1); s.position = CGPoint(x: x, y: -y); s.zPosition = z; s.isHidden = true
            host.addChild(s); return s
        }
        let gc = tex.gaugeClear
        gaugeRed = bar(UIColor(hexString: "#ff3408"), y: 32, h: 20, x: 0, z: 0.1)
        gaugeRedTop = bar(UIColor(hexString: "#ffa191"), y: 30, h: 3, x: 0, z: 0.11)
        gaugeYel = bar(UIColor(hexString: "#ffff00"), y: 10, h: 42, x: gc + 9, z: 0.1)
        gaugeYelTop = bar(.white, y: 8, h: 3, x: gc + 9, z: 0.11)
        _ = local(tex.gaugeTicks, 792, 56, z: 0.2)
        clearMarkSprite = local(tex.clearMark[0], 792, 56, z: 0.3)

        soulSprite = SKSpriteNode(texture: tex.soul[0], size: CGSize(width: 50, height: 46))
        soulSprite.anchorPoint = CGPoint(x: 0, y: 1)
        soulSprite.position = CGPoint(x: W - 57 - 23, y: Y(165 - 21)); soulSprite.zPosition = 6.2
        addChild(soulSprite)
    }

    /// 원본 .donbg : a 레이어(가로 스크롤) + b 레이어(스크롤 + 위아래로 들썩)
    /// SKCropNode 는 매 프레임 오프스크린 렌더링을 해서 느리므로 쓰지 않는다.
    /// (넘치는 부분은 위쪽은 화면 밖, 아래쪽은 z=2 의 검은 프레임이 가려 준다)
    private func buildDonBg(id: Int) {
        guard let ia = Gfx.image("bg_don_\(id)a"), let ib = Gfx.image("bg_don_\(id)b") else { return }
        let hBox: CGFloat = 184.5
        let scroll: TimeInterval = id == 3 ? 3.4 : (id == 5 ? 2.7 : 5)
        let dist = hBox / ia.size.height * max(ia.size.width, ib.size.width)

        let root = SKNode(); root.position = CGPoint(x: 0, y: Y(0)); root.zPosition = 1.2
        addChild(root)

        // 레이어 1
        let tw1 = ia.size.width * hBox / ia.size.height
        let texA = Gfx.texture("bg_don_\(id)a")
        let l1 = SKNode()
        for k in 0..<(Int(ceil(W / tw1)) + 2) {
            let t = SKSpriteNode(texture: texA, size: CGSize(width: tw1, height: hBox))
            t.anchorPoint = CGPoint(x: 0, y: 1); t.position = CGPoint(x: CGFloat(k) * tw1, y: 0)
            l1.addChild(t)
        }
        l1.run(.repeatForever(.sequence([.moveBy(x: -tw1, y: 0, duration: scroll), .moveTo(x: 0, duration: 0)])))
        root.addChild(l1)

        // 레이어 2
        let h2 = hBox * ib.size.height / ia.size.height
        let tw2 = ib.size.width * h2 / ib.size.height
        let n2 = max(1, Int((dist / tw2).rounded()))
        let dist2 = CGFloat(n2) * tw2
        let texB = Gfx.texture("bg_don_\(id)b")
        let l2 = SKNode()
        for k in 0..<(Int(ceil(W / tw2)) + n2 + 2) {
            let t = SKSpriteNode(texture: texB, size: CGSize(width: tw2, height: h2))
            t.anchorPoint = CGPoint(x: 0, y: 1); t.position = CGPoint(x: CGFloat(k) * tw2, y: 0)
            l2.addChild(t)
        }
        l2.run(.repeatForever(.sequence([.moveBy(x: -dist2, y: 0, duration: scroll * Double(dist2 / dist)),
                                         .moveTo(x: 0, duration: 0)])))
        let bob = SKNode()
        bob.addChild(l2)
        let raise = max(0, (ib.size.height - ia.size.height) / ib.size.height * hBox)
        if raise > 0 {
            let d: TimeInterval = id == 3 ? 0.9 : (id == 5 ? 1.1 : 1.0)
            bob.run(.repeatForever(.sequence([.moveBy(x: 0, y: raise, duration: d), .moveBy(x: 0, y: -raise, duration: d)])))
        }
        root.addChild(bob)
    }

    // MARK: 악보 데이터 준비

    private func prepareChart() {
        let notes = chart.notes
        let n = notes.count
        nTime = notes.map { $0.time }
        nEnd = notes.map { max($0.time, $0.endTime) }
        nType = notes.map { $0.type }
        nBalloon = notes.map { $0.balloon }
        nPps = notes.map { pxPerMs($0.speed) }
        gogoRanges = chart.gogo.sorted { $0.0 < $1.0 }
        nGogo = notes.map { note in gogoRanges.contains { note.time >= $0.0 && note.time < $0.1 } }
        nodeFor = Array(repeating: nil, count: n)
        activePos = Array(repeating: -1, count: n)
        judged = Array(repeating: false, count: n)
        for i in 0..<n {
            if (1...4).contains(nType[i]) { judgeList.append(i) }
            if nType[i] >= 5 { rollList.append(i) }
            if nType[i] == 7 { balloonLeft[i] = max(nBalloon[i], 1) }
        }
        let span = Double(W + 120 - slot.x)
        appear = (0..<n).map { nTime[$0] - span / nPps[$0] }
        spawnOrder = Array(0..<n).sorted { appear[$0] < appear[$1] }
        endTime = nEnd.max() ?? 0
    }

    // MARK: 노드 풀

    private func zFor(_ i: Int) -> CGFloat {
        // 원본은 뒤쪽 노트부터 그려서 앞 노트가 위에 옴
        3.0 + 0.4 * CGFloat(nTime.count - i) / CGFloat(max(1, nTime.count))
    }

    private func takeNote(_ type: Int) -> SKSpriteNode {
        let s: SKSpriteNode
        if let p = poolNote.popLast() { s = p }
        else { s = SKSpriteNode(); s.size = tex.noteSize; addChild(s) }
        switch type {
        case 1: s.texture = tex.smallDon
        case 2: s.texture = tex.smallKa
        case 3: s.texture = tex.bigDon
        default: s.texture = tex.bigKa
        }
        s.size = tex.noteSize
        s.isHidden = false
        return s
    }
    private func takeBar() -> SKSpriteNode {
        if let p = poolBar.popLast() { p.isHidden = false; return p }
        let s = SKSpriteNode(color: UIColor(hexString: "#bdbdbd"), size: CGSize(width: 3, height: 130))
        addChild(s)
        return s
    }
    private func takeRoll() -> RollNode {
        if let p = poolRoll.popLast() { p.isHidden = false; return p }
        let r = RollNode(); addChild(r); return r
    }
    private func takeBalloon() -> BalloonNode {
        if let p = poolBalloon.popLast() { p.isHidden = false; return p }
        let b = BalloonNode(tex); addChild(b); return b
    }

    private func spawn(_ i: Int) {
        let ty = nType[i]
        let node: SKNode
        switch ty {
        case 0: node = takeBar()
        case 1, 2, 3, 4: node = takeNote(ty)
        case 5, 6:
            let r = takeRoll()
            r.configure(tex, big: ty == 6, endX: CGFloat((nEnd[i] - nTime[i]) * nPps[i]))
            node = r
        default:
            let b = takeBalloon()
            b.count.set(balloonLeft[i] ?? max(nBalloon[i], 1), advance: 14)
            node = b
        }
        node.zPosition = ty == 0 ? 2.7 : zFor(i)
        node.position = CGPoint(x: W + 200, y: Y(slot.y))
        nodeFor[i] = node
        activePos[i] = active.count
        active.append(i)
    }

    private func removeNode(_ i: Int) {
        guard let node = nodeFor[i] else { return }
        node.isHidden = true
        switch nType[i] {
        case 0: poolBar.append(node as! SKSpriteNode)
        case 1, 2, 3, 4: poolNote.append(node as! SKSpriteNode)
        case 5, 6: poolRoll.append(node as! RollNode)
        default: poolBalloon.append(node as! BalloonNode)
        }
        nodeFor[i] = nil
        let pos = activePos[i]
        if pos >= 0 {
            let last = active.count - 1
            if pos != last { let moved = active[last]; active[pos] = moved; activePos[moved] = pos }
            active.removeLast()
            activePos[i] = -1
        }
    }

    // MARK: 프레임 업데이트

    override func update(_ currentTime: TimeInterval) {
        guard started, !finished else { return }
        let t = nowMs()
        let dt = lastFrame == 0 ? 16.7 : min(100, (currentTime - lastFrame) * 1000)
        lastFrame = currentTime

        while spawnPtr < spawnOrder.count && appear[spawnOrder[spawnPtr]] <= t {
            spawn(spawnOrder[spawnPtr]); spawnPtr += 1
        }

        // 화면 위의 노트만 이동 (정렬/탐색 없이 활성 배열만 순회)
        var k = 0
        let slotX = slot.x
        while k < active.count {
            let i = active[k]
            guard let node = nodeFor[i] else { k += 1; continue }
            let ty = nType[i]
            let pps = nPps[i]
            var x = slotX + CGFloat((nTime[i] - t) * pps)
            if ty == 7 {
                if t >= nTime[i] && t <= nEnd[i] { x = slotX }
                else if t > nEnd[i] { x = slotX + CGFloat((nEnd[i] - t) * pps) }   // 터뜨리지 못한 풍선은 그대로 흘러감
            }
            node.position.x = x
            let right = (ty == 5 || ty == 6) ? x + CGFloat((nEnd[i] - nTime[i]) * pps) : x
            if right < laneLeft - 120 { removeNode(i) } else { k += 1 }
        }

        // 놓친 노트
        while judgePtr < judgeList.count {
            let ni = judgeList[judgePtr]
            if judged[ni] { judgePtr += 1; continue }
            if nTime[ni] + rules.bad < t {
                judged[ni] = true; judgePtr += 1
                combo = 0; res.miss += 1; addGauge(soul.bad); setDark(true); refreshHUD()
            } else { break }
        }

        // 고고타임
        while gogoIdx < gogoRanges.count && t >= gogoRanges[gogoIdx].1 { gogoIdx += 1 }
        let gogo = gogoIdx < gogoRanges.count && t >= gogoRanges[gogoIdx].0
        if gogo && !wasGogo { dancer.trigger("gogostart", at: t, beats: 1.5); gogoStartMs = t; gogoEventMs = t }
        if !gogo && wasGogo { gogoEndMs = t; gogoEventMs = t }
        wasGogo = gogo

        updateFire(t, gogo)
        updateExplosion(t)
        updateHitFx(t)
        updateInputFx(t, gogo: gogo)
        updateFlies(t)
        updateDark(dt)
        dancer.update(t: t, gogo: gogo, cleared: rules.clearReached(gauge))

        // 콤보 숫자 튀는 효과 (원본: 100ms 동안 세로 1~1.125배)
        if combo >= 10 {
            let u = (t - scoreMs) / 100
            comboNode.yScale = (u >= 0 && u < 1) ? 1 + fade(CGFloat(u)) / 8 : 1
        }

        if t > endTime + 1500 { finish() }
    }

    private func fade(_ p: CGFloat) -> CGFloat {
        var x = p
        if x < 0.5 { x = 1 - x }
        return (1 - cos(.pi * x * 2)) / 2
    }

    /// 고고타임 불꽃 (원본 "bar" 에셋: 커지며 나타났다 사라짐)
    private func updateFire(_ t: Double, _ gogo: Bool) {
        // 고고 배경 그라데이션 (터치 모드: 페이드 없이 켜짐, 끝난 뒤 0.1초 유지)
        gogoBar.isHidden = !(gogo || t <= gogoEventMs + 100)

        var grow: CGFloat
        if gogo {
            let e = t - gogoStartMs
            grow = CGFloat(3 - min(200, e) / 100)
            fire.alpha = CGFloat(min(200, e) / 200)
        } else {
            let e = t - gogoEndMs
            grow = CGFloat(1 - min(100, e) / 100)
            fire.alpha = 1
        }
        if grow <= 0.01 || (!gogo && t - gogoEndMs > 100) { fire.isHidden = true; return }
        fire.isHidden = false
        fire.size = CGSize(width: 360 * grow, height: 370 * grow)
        let idx = ((Int(floor(t / (chart.beatMs / 8))) % 7) + 7) % 7
        if idx != lastFireIdx { lastFireIdx = idx; fire.texture = tex.fire[idx] }
    }

    /// 노트 폭발 (원본 explosion: 60fps 기준 7/14 프레임, 터치 모드는 투명도 페이드 없음)
    private func updateExplosion(_ t: Double) {
        let frame = Int((t - exStart) / (1000.0 / 60.0))
        let total = exBig ? 14 : 7
        if frame < 0 || frame >= total { explosion.isHidden = true; lastExKey = -1; return }
        var mul: CGFloat = 1
        if exType < 2 && frame < 2 { mul *= 1 - CGFloat(frame + 1) * 0.2 }
        let row = min(3, frame / 2)
        let key = exType * 10 + row
        if key != lastExKey { lastExKey = key; explosion.texture = tex.explosion[exType][row] }
        explosion.size = CGSize(width: 222 * mul, height: 222 * mul)
        explosion.isHidden = false
    }

    /// 히트 그림자 + 良/可/不可 글자 (원본: 300ms 동안 표시, 글자는 13px 떠오름)
    private func updateHitFx(_ t: Double) {
        let sm = t - scoreMs
        if sm >= 0 && sm < 300 && scoreType > 0 {
            hitFx.isHidden = false
        } else { hitFx.isHidden = true }

        if sm >= 0 && sm < 300 && !judgeKey.isEmpty {
            let yOff = sm < 70 ? CGFloat(sm) * (13.0 / 70.0) : 0
            judgeSprite.position = CGPoint(x: slot.x, y: Y(slot.y - 98 - yOff) + 8 * 1.35)
            judgeSprite.isHidden = false
        } else { judgeSprite.isHidden = true }
    }

    /// 북 눌림 / 노트 바 번쩍임 / 북 이미지 눌림 — 전부 마지막 입력 시각에서 계산 (SKAction 없음)
    private func updateInputFx(_ t: Double, gogo: Bool) {
        for i in 0..<4 {
            let age = t - keyTime[i]
            drumKeys[i].isHidden = !(age >= 0 && age < 130)
        }
        drumImg.position.y = (t - touchMs >= 0 && t - touchMs < 100) ? drumBaseY - 7 : drumBaseY

        let sound = lastDonMs > lastKaMs ? lastDonMs : lastKaMs
        let isDon = lastDonMs > lastKaMs
        let age = t - sound
        if age >= 0 && age < 130 {
            let a = CGFloat((1 - age / 130) / 5)
            let main = isDon ? flashDon : flashKa
            let other = isDon ? flashKa : flashDon
            main.isHidden = false; main.alpha = a
            other.isHidden = true
            if scoreMs > t - 130 { flashYellow.isHidden = false; flashYellow.alpha = a } else { flashYellow.isHidden = true }
        } else {
            flashDon.isHidden = true; flashKa.isHidden = true; flashYellow.isHidden = true
        }
    }

    private func updateDark(_ dt: Double) {
        let step = CGFloat(dt / 150) * 0.5
        if darkAlpha < darkTarget { darkAlpha = min(darkTarget, darkAlpha + step) }
        else if darkAlpha > darkTarget { darkAlpha = max(darkTarget, darkAlpha - step) }
        darkBg.alpha = darkAlpha
    }
    private func setDark(_ on: Bool) { darkTarget = on ? 0.5 : 0 }

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
        // 1) 소리부터 (미리 디코딩된 풀에서 바로 재생)
        audio.playSfx(don: isDon)

        // 2) 상태만 기록 — 화면 효과는 update() 가 시각을 보고 알아서 그림
        let t = songMs(uptime)
        let keyIdx = isDon ? (left ? 2 : 3) : (left ? 0 : 1)
        keyTime[keyIdx] = t
        if isDon { lastDonMs = t } else { lastKaMs = t }
        touchMs = t

        // 연타/풍선
        for ri in rollList where !doneRolls.contains(ri) {
            guard t >= nTime[ri] - 10 && t <= nEnd[ri] else { continue }
            res.rollHits += 1
            let ty = nType[ri]
            if ty == 7 {
                let leftHits = (balloonLeft[ri] ?? 1) - 1
                balloonLeft[ri] = leftHits
                if leftHits <= 0 {
                    doneRolls.insert(ri); res.score += 5000; removeNode(ri)
                    audio.play("se_balloon")
                } else {
                    res.score += 300
                    (nodeFor[ri] as? BalloonNode)?.count.set(leftHits, advance: 14)
                }
            } else {
                res.score += ty == 6 ? 200 : 100          // 원본 checkDrumroll: 100점 (큰 연타는 ×2)
                spawnFly(big: ty == 6, don: isDon, at: t)
            }
            setDark(false)
            refreshHUD(); return
        }

        while judgePtr < judgeList.count && judged[judgeList[judgePtr]] { judgePtr += 1 }
        guard judgePtr < judgeList.count else { return }
        let ni = judgeList[judgePtr]
        let rel = abs(t - nTime[ni])
        if rel >= rules.bad { return }

        let noteIsDon = (nType[ni] == 1 || nType[ni] == 3)
        let big = nType[ni] >= 3

        if noteIsDon != isDon {
            // 틀린 북: 놓치지 않은 노트는 그대로 남고 不可 로만 집계 (원본: good 범위 안에서만 반응)
            if rel >= rules.good { return }
            judged[ni] = true
            combo = 0; res.bad += 1; addGauge(soul.bad); setDark(true)
            refreshHUD(); return
        }

        judged[ni] = true
        removeNode(ni)
        if rel < rules.good {
            registerHit(ni, base: 450, big: big); res.good += 1; addGauge(soul.good)
            showJudge(type: 450, big: big, t: t, don: noteIsDon)
        } else if rel < rules.ok {
            registerHit(ni, base: 230, big: big); res.ok += 1; addGauge(soul.ok)
            showJudge(type: 230, big: big, t: t, don: noteIsDon)
        } else {
            combo = 0; res.bad += 1; addGauge(soul.bad)
            showJudge(type: 0, big: big, t: t, don: noteIsDon)
        }
        refreshHUD()
    }

    /// 판정 결과 표시 (원본 view.displayScore)
    private func showJudge(type: Int, big: Bool, t: Double, don: Bool) {
        scoreMs = t; scoreType = type; scoreBig = big
        judgeKey = type == 450 ? "good" : (type == 230 ? "ok" : "bad")
        judgeSprite.texture = tex.judge[judgeKey]
        judgeSprite.size = tex.judgeSize[judgeKey] ?? .zero
        if type > 0 {
            hitFx.texture = tex.hit[(type == 230 ? 0 : 1) + (big ? 2 : 0)]
            exType = (big ? 0 : 2) + (type == 450 ? 0 : 1); exBig = big; exStart = t
            spawnFly(big: big, don: don, at: t)
            if combo > 0 && combo % 10 == 0 { dancer.trigger("10combo", at: t, beats: 1.5) }
            if combo == 50 || (combo > 0 && combo % 100 == 0 && combo <= 5000) { audio.play("v_combo_\(combo)") }
        }
        setDark(type == 0)
    }

    /// 원본 updateGlobalScore: (기본 450/230 + 콤보 보너스) × (큰 노트 2배) × (고고 1.2배), 10점 단위 내림
    private func registerHit(_ i: Int, base: Int, big: Bool) {
        combo += 1
        res.maxCombo = max(res.maxCombo, combo)
        let bonus = max(0, ((min(combo, 100) - 1) / 10) * 100)
        var mul = big ? 2.0 : 1.0
        if nGogo[i] { mul *= 1.2 }
        res.score += Int(floor(Double(base + bonus) * mul / 10)) * 10
    }

    // MARK: 날아가는 노트 (원본 animateBezier: 490ms 이동 후 160ms 머물다 사라짐)

    private func spawnFly(big: Bool, don: Bool, at t: Double) {
        let node: SKSpriteNode
        if let p = flyPool.popLast() { node = p }
        else { node = SKSpriteNode(); node.size = tex.noteSize; node.zPosition = 7; addChild(node) }
        node.texture = big ? (don ? tex.bigDon : tex.bigKa) : (don ? tex.smallDon : tex.smallKa)
        node.isHidden = false
        node.position = CGPoint(x: slot.x + 14, y: Y(slot.y - 29))
        flies.append(Fly(node: node, start: t))
    }

    private func updateFlies(_ t: Double) {
        if flies.isEmpty { return }
        let x1 = slot.x + 14, y1 = slot.y - 29
        let x2 = W - 55, y2: CGFloat = 165
        let w = x2 - x1, h = y1 - y2
        let p0 = CGPoint(x: x1, y: y1), p1 = CGPoint(x: x1 + w / 6, y: y1 - h * 3.5)
        let p2 = CGPoint(x: x2 - w / 3, y: y2 - h * 5), p3 = CGPoint(x: x2, y: y2)
        var i = 0
        while i < flies.count {
            let e = t - flies[i].start
            if e >= 650 {
                flies[i].node.isHidden = true
                flyPool.append(flies[i].node)
                flies.swapAt(i, flies.count - 1); flies.removeLast()
                continue
            }
            let a = e < 490 ? e / 490 : 1
            let u = CGFloat(sin(Double.pi / 2 * max(0, a)))      // easeOut
            let v = 1 - u
            let bx = v*v*v*p0.x + 3*v*v*u*p1.x + 3*v*u*u*p2.x + u*u*u*p3.x
            let by = v*v*v*p0.y + 3*v*v*u*p1.y + 3*v*u*u*p2.y + u*u*u*p3.y
            flies[i].node.position = CGPoint(x: bx, y: Y(by))
            i += 1
        }
    }

    private func addGauge(_ v: Double) { gauge = min(max(gauge + v, 0), 10000) }

    private func refreshHUD() {
        scoreNode.set(res.score, advance: 29)
        if combo >= 10 {
            let orange = combo >= 100
            if orange != comboOrange {
                comboOrange = orange
                comboNode.replaceTextures(tex.comboDigits[orange ? 1 : 0])
            }
            comboNode.set(combo, advance: combo >= 1000 ? 38 : 42)
            comboWord.texture = tex.comboWord[orange ? 1 : 0]
            comboNode.isHidden = false; comboWord.isHidden = false
        } else {
            comboNode.isHidden = true; comboWord.isHidden = true
        }
        updateGauge()
    }

    private func updateGauge() {
        let pct = rules.gaugePercent(gauge)
        let sig = Int(pct * 50)
        if sig == lastGaugeSig { return }
        lastGaugeSig = sig
        let gw = GameTextures.gaugeW, gc = tex.gaugeClear
        let filled = gw * CGFloat(pct)
        let cleared = pct >= rules.gaugeClear

        if filled > 0 {
            let w = max(0, min(gw - 5, gc + 1, filled - 4))
            gaugeRed.isHidden = w <= 0; gaugeRedTop.isHidden = w <= 0
            gaugeRed.size.width = w; gaugeRedTop.size.width = w
        } else { gaugeRed.isHidden = true; gaugeRedTop.isHidden = true }

        if filled > gc + 14 {
            let w = min(gw - 4, filled - gc - 14)
            gaugeYel.isHidden = false; gaugeYelTop.isHidden = false
            gaugeYel.size.width = w; gaugeYelTop.size.width = w
        } else { gaugeYel.isHidden = true; gaugeYelTop.isHidden = true }

        if cleared != lastGaugeCleared {
            lastGaugeCleared = cleared
            clearMarkSprite.texture = tex.clearMark[cleared ? 1 : 0]
            soulSprite.texture = tex.soul[cleared ? 1 : 0]
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
        res.gaugePercent = rules.gaugePercent(gauge)
        res.cleared = rules.clearReached(gauge)
        onFinish?(res)
    }
}
