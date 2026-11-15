import SwiftUI
import UIKit

// MARK: 루트 (타이틀 → 곡 목록)

struct RootView: View {
    @State private var started = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            if started {
                SongListView().transition(.opacity)
            } else {
                TitleView { withAnimation(.easeInOut(duration: 0.3)) { started = true } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
        .onAppear {
            // 첫 터치에서 멈칫하지 않도록 소리/BGM 을 미리 준비
            Sfx.shared.preload(["se_don", "v_title", "se_gameclear", "se_gamefail", "v_results"])
            Bgm.shared.prewarm("bgm_songsel")
            SystemGuard.applyRepeatedly()
        }
        // 앱을 나가면 모든 소리 정지, 돌아오면 필요한 것만 다시 시작
        .onChange(of: scenePhase) { phase in
            if phase == .background { AppAudio.enterBackground() }
            else if phase == .active { AppAudio.becomeActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in AppAudio.enterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in AppAudio.enterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in AppAudio.becomeActive() }
    }
}

// MARK: 타이틀 (원본 title-screen.png + 로고 + 깜빡이는 안내문)

struct OutlinedText: View {
    let text: String
    let size: CGFloat
    var fill: Color = .white
    var outline: Color = .red
    var body: some View {
        let font = Font.custom(Fonts.tnt, size: size)
        let d = size * 0.07
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                Text(text).font(font).foregroundColor(outline)
                    .offset(x: CGFloat(cos(a)) * d, y: CGFloat(sin(a)) * d)
            }
            Text(text).font(font).foregroundColor(fill)
        }
    }
}

struct TitleView: View {
    let onStart: () -> Void
    @State private var blink = false

    var body: some View {
        GeometryReader { geo in
            let vmin = min(geo.size.width, geo.size.height)
            ZStack {
                Color(hex: "#1389f0") ?? .blue
                if let im = Gfx.image("title-screen") {
                    Image(uiImage: im).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                Image(uiImage: LogoRenderer.image).resizable().scaledToFit().frame(width: vmin)
                VStack {
                    Spacer()
                    OutlinedText(text: "タッチしてスタート！", size: vmin * 0.08)
                        .opacity(blink ? 0.2 : 1)
                        .padding(.bottom, geo.size.height * 0.15)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { Sfx.shared.play("se_don"); onStart() }
        .onAppear {
            Sfx.shared.play("v_title")
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { blink = true }
        }
    }
}

// MARK: 겹겹이 테두리 글자 (원본 draw.layeredText 대용)

struct TextLayer {
    var stroke: UIColor? = nil
    var width: CGFloat = 0
    var fill: UIColor? = nil
    var dx: CGFloat = 0
    var dy: CGFloat = 0
}

enum LayeredText {
    static func render(_ text: String, size: CGFloat, layers: [TextLayer]) -> (UIImage, CGFloat) {
        let font = Fonts.tntFont(size)
        let ts = (text as NSString).size(withAttributes: [.font: font])
        let pad = (layers.map { $0.width }.max() ?? 0) + 6
        let imgSize = CGSize(width: ceil(ts.width + pad * 2), height: ceil(ts.height + pad * 2))
        let img = Gfx.renderer(imgSize, scale: 2).image { _ in
            for l in layers {
                let pt = CGPoint(x: pad + l.dx, y: pad + l.dy)
                if let s = l.stroke {
                    (text as NSString).draw(at: pt, withAttributes: [
                        .font: font, .strokeColor: s, .strokeWidth: l.width / size * 100,
                        .foregroundColor: UIColor.clear])
                }
                if let f = l.fill {
                    (text as NSString).draw(at: pt, withAttributes: [.font: font, .foregroundColor: f])
                }
            }
        }
        return (img, pad)
    }
}

extension Array where Element == TextLayer {
    static var outlined: [TextLayer] { [TextLayer(stroke: .black, width: 10), TextLayer(fill: .white)] }
    static var heading: [TextLayer] {
        [TextLayer(stroke: .black, width: 16, dx: -2, dy: -2),
         TextLayer(stroke: UIColor(hexString: "#ad1516"), width: 10, dx: 2, dy: 2),
         TextLayer(stroke: UIColor(hexString: "#ff797b"), width: 6, dx: -2, dy: -2),
         TextLayer(stroke: UIColor(hexString: "#f70808"), width: 6),
         TextLayer(fill: .white)]
    }
    static func filled(_ c: UIColor) -> [TextLayer] { [TextLayer(stroke: .black, width: 8), TextLayer(fill: c)] }
}

/// 디자인 좌표(1280x720 기준)에 글자를 놓는 뷰
struct LText: View {
    enum Align { case leading, center, trailing }
    let text: String
    let size: CGFloat
    let x: CGFloat
    let y: CGFloat
    var align: Align = .leading
    var layers: [TextLayer] = .outlined

    var body: some View {
        let (img, pad) = LayeredText.render(text, size: size, layers: layers)
        let w = img.size.width, h = img.size.height
        let px: CGFloat = {
            switch align {
            case .leading: return x - pad + w / 2
            case .center: return x
            case .trailing: return x + pad - w / 2
            }
        }()
        Image(uiImage: img).position(x: px, y: y - pad + h / 2)
    }
}

// MARK: 결과 화면 (원본 scoresheet.js 의 레이아웃/색)

struct ResultView: View {
    let title: String
    let course: String
    let r: ResultData
    let close: () -> Void
    @State private var blink = false
    @State private var canClose = false      // 곡 끝날 때 연타하다 바로 닫히지 않게 1.5초 뒤부터 탭 허용

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Color, radius: CGFloat = 0) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(c).frame(width: w, height: h).position(x: x + w / 2, y: y + h / 2)
    }

    private func pattern(_ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            if let img = Gfx.image("bg_score_p1") {
                Rectangle().fill(ImagePaint(image: Image(uiImage: img), scale: 1 / 1.55))
                    .frame(width: w, height: h).position(x: w / 2, y: y + h / 2)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 1280, geo.size.height / 720)
            let dw = geo.size.width / scale, dh = geo.size.height / scale
            let fl = (dw - 1280) / 2, ft = (dh - 720) / 2
            ZStack(alignment: .topLeading) {
                background(dw, dh)
                content(fl, ft)
            }
            .frame(width: dw, height: dh, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            guard canClose else { return }
            Sfx.shared.play("se_don"); close()
        }
        .onAppear {
            Sfx.shared.play(r.cleared ? "se_gameclear" : "se_gamefail")
            Sfx.shared.play("v_results")
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { blink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { canClose = true }
        }
    }

    private func background(_ w: CGFloat, _ h: CGFloat) -> some View {
        let mid = h / 2
        return ZStack(alignment: .topLeading) {
            Group {
                pattern(0, w, mid)
                box(0, mid - 12, w, 12, Color(red: 127/255, green: 28/255, blue: 12/255).opacity(0.5))
                box(0, mid, w, 20, Color.black.opacity(0.25))
                box(0, 0, w, 64 + (h - 720) / 2, Color(hex: "#fa4529") ?? .red)
                box(0, 64 + (h - 720) / 2, w, 8, Color(hex: "#bf2900") ?? .red)
            }
            Group {
                pattern(mid, w, mid)
                box(0, mid, w, 12, Color(red: 249/255, green: 163/255, blue: 149/255).opacity(0.5))
                box(0, mid - 2, w, 4, .black)
                box(0, h - 64 - (h - 720) / 2, w, 64 + (h - 720) / 2, Color(hex: "#fa4529") ?? .red)
                box(0, h - 72 - (h - 720) / 2, w, 7, Color(red: 1, green: 144/255, blue: 116/255).opacity(0.8))
                box(0, h - 66 - (h - 720) / 2, w, 2, Color(hex: "#ff9b7a") ?? .red)
            }
        }
    }

    private func content(_ fl: CGFloat, _ ft: CGFloat) -> some View {
        let diffIdx = ["easy": 0, "normal": 1, "hard": 2, "oni": 3, "ura": 4][course] ?? 3
        let diffNames = ["easy": "かんたん", "normal": "ふつう", "hard": "むずかしい", "oni": "おに", "ura": "おに"]
        let pct = Int(r.gaugePercent * 100)
        let filled = Int(r.gaugePercent * 50)
        let clearIdx = 35
        return ZStack(alignment: .topLeading) {
            Group {
            LText(text: "成績発表", size: 48, x: 23, y: 15, layers: .heading)
            LText(text: title, size: 40, x: 1257, y: 20, align: .trailing, layers: .outlined)

            if let icon = Gfx.cropImage("difficulty", CGRect(x: 0, y: 144 * diffIdx, width: 168, height: 143)) {
                Image(uiImage: icon).resizable().frame(width: 189, height: 162).position(x: 300 + 94.5, y: 150 + 81)
            }
            LText(text: diffNames[course] ?? "おに", size: 28, x: 395, y: 308 - 30, align: .center, layers: .outlined)
            // 왕관: 클리어=은, 풀콤보(不可 0)=금 (원본 scoresheet 와 같은 위치)
            if !r.crown.isEmpty {
                Image(systemName: "crown.fill")
                    .font(.system(size: 64))
                    .foregroundColor(r.crown == "gold" ? (Color(hex: "#ffd43a") ?? .yellow) : Color(white: 0.85))
                    .shadow(color: .white, radius: 2)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 2)
                    .position(x: 395, y: 218)
            }
            }
            Group {
            box(532, 98, 728, 232, Color(red: 1, green: 224/255, blue: 216/255).opacity(0.8), radius: 30)
            box(556, 237, 254, 70, .black, radius: 15)
            box(559, 240, 248, 64, Color(hex: "#eec954") ?? .yellow, radius: 14)
            box(567, 248, 232, 48, .black, radius: 6)
            LText(text: "点", size: 36, x: 792, y: 253, align: .trailing, layers: [TextLayer(fill: .white)])
            LText(text: "\(r.score)", size: 36, x: 752, y: 253, align: .trailing, layers: [TextLayer(fill: .white)])
            LText(text: r.isRecord ? "新記録！" : "ベスト \(r.best)", size: 24, x: 560, y: 312, align: .leading,
                  layers: .filled(r.isRecord ? UIColor(hexString: "#ffd43a") : .white))
            }

            // 판정 집계
            Group {
            LText(text: "良", size: 34, x: 600, y: 120, layers: .filled(UIColor(hexString: "#ffd43a")))
            LText(text: "\(r.good)", size: 34, x: 840, y: 120, align: .trailing, layers: .outlined)
            LText(text: "可", size: 34, x: 600, y: 170, layers: .filled(.white))
            LText(text: "\(r.ok)", size: 34, x: 840, y: 170, align: .trailing, layers: .outlined)
            }
            Group {
            LText(text: "不可", size: 34, x: 880, y: 120, layers: .filled(UIColor(hexString: "#6aa8ff")))
            LText(text: "\(r.bad + r.miss)", size: 34, x: 1220, y: 120, align: .trailing, layers: .outlined)
            LText(text: "連打数", size: 30, x: 880, y: 170, layers: .outlined)
            LText(text: "\(r.rollHits)", size: 34, x: 1220, y: 170, align: .trailing, layers: .outlined)
            LText(text: "最大コンボ数", size: 30, x: 880, y: 225, layers: .outlined)
            LText(text: "\(r.maxCombo)", size: 34, x: 1220, y: 225, align: .trailing, layers: .outlined)

            }

            // 하단: 게이지 + 클리어 여부
            Group {
            LText(text: r.cleared ? "クリア！" : "もうすこし…", size: 64, x: 640, y: 380, align: .center,
                  layers: .filled(r.cleared ? UIColor(hexString: "#ffd43a") : UIColor(white: 0.85, alpha: 1)))
            HStack(spacing: 2) {
                ForEach(0..<50, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? (i >= clearIdx ? Color(hex: "#ffe400") ?? .yellow : Color(hex: "#f58c00") ?? .orange)
                                         : Color(white: 0.2))
                        .frame(width: 12, height: 26)
                }
            }
            .padding(4).background(Color.black.opacity(0.7)).cornerRadius(6)
            .position(x: 640, y: 500)
            LText(text: "\(pct)%", size: 36, x: 640, y: 535, align: .center, layers: .outlined)
            LText(text: "タッチでもどる", size: 30, x: 640, y: 600, align: .center, layers: .outlined)
                .opacity(canClose ? (blink ? 0.2 : 1) : 0)
            }
        }
        .frame(width: 1280, height: 720, alignment: .topLeading)
        .offset(x: fl, y: ft)
    }
}
