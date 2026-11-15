import SwiftUI
import UIKit

/// Taikoi 공통 디자인 — 결과 화면(scoresheet)의 주황/빨강 계열을 앱 전체에 맞춘다.
enum Theme {
    static let red = Color(hex: "#fa4529") ?? .red
    static let redDark = Color(hex: "#bf2900") ?? .red
    static let gold = Color(hex: "#ffd43a") ?? .yellow
    static let panel = Color(white: 0.13)
    static let panelLight = Color(white: 0.2)
    static let corner: CGFloat = 12

    static func title(_ size: CGFloat) -> Font { .custom(Fonts.tnt, size: size) }
    static func body(_ size: CGFloat) -> Font { .custom(Fonts.kozuka, size: size) }

    /// 앱 시작 때 한 번: 시스템 컨트롤(세그먼트 등)도 같은 색으로
    static func applyAppearance() {
        let seg = UISegmentedControl.appearance()
        seg.selectedSegmentTintColor = UIColor(red: 250 / 255, green: 69 / 255, blue: 41 / 255, alpha: 1)
        seg.backgroundColor = UIColor(white: 0.18, alpha: 1)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)

        // 상단바 제목은 SwiftUI 커스텀 항목 대신 UIKit 기본 제목에 글꼴만 입힌다
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(red: 250 / 255, green: 69 / 255, blue: 41 / 255, alpha: 1)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white, .font: Fonts.tntFont(24)]
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.compactAppearance = nav
        bar.scrollEdgeAppearance = nav
    }
}

/// 원본 bg-pattern-1.png 타일 배경. 한 번만 이미지 한 장으로 합쳐 두고 재사용한다
/// (타일 + 투명도 + 덮개를 매 프레임 합성하면 스크롤/터치 때 끊김의 원인이 됨).
enum PatternImage {
    private static var cached: UIImage?

    static func make() -> UIImage? {
        if let c = cached { return c }
        let b = UIScreen.main.bounds.size
        let size = CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
        let f = UIGraphicsImageRendererFormat()
        f.scale = min(2, UIScreen.main.scale); f.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            UIColor(hexString: "#ff5a2b").setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let tile = Gfx.image("bg-pattern-1") {
                let tw = tile.size.width, th = tile.size.height
                if tw > 0, th > 0 {
                    var y: CGFloat = 0
                    while y < size.height {
                        var x: CGFloat = 0
                        while x < size.width {
                            tile.draw(in: CGRect(x: x, y: y, width: tw, height: th), blendMode: .normal, alpha: 0.5)
                            x += tw
                        }
                        y += th
                    }
                }
            }
            UIColor.black.withAlphaComponent(0.35).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        cached = img
        return img
    }
}

struct PatternBackground: View {
    var body: some View {
        ZStack {
            Color(hex: "#ff5a2b") ?? .orange
            if let img = PatternImage.make() {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: 공통 스타일

/// 하단 바/버튼: 둥근 어두운 패널 + 흰 글씨, 눌렀을 때 살짝 밝아짐
struct TaikoButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(prominent ? Theme.red : (configuration.isPressed ? Theme.panelLight : Theme.panel))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Color.black.opacity(0.5), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// 분류 켜기/끄기 칩 (체크 표시)
struct CategoryChip: View {
    let name: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundColor(on ? Theme.gold : .white.opacity(0.7))
                Text(name).font(Theme.body(14)).foregroundColor(.white.opacity(on ? 1 : 0.6))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.panelLight : Theme.panel.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.gold.opacity(0.8) : Color.black.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// 빨간 상단 바 (결과 화면과 같은 색)
    func taikoNavBar() -> some View {
        self
            .toolbarBackground(Theme.red, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// 설정 같은 Form 을 앱 배경/패널 색으로
    func taikoForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(PatternBackground())
            .tint(Theme.gold)
    }

    func taikoRow() -> some View { self.listRowBackground(Theme.panel) }
}

/// Form/List 섹션 머리글
struct TaikoHeader: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(Theme.title(17)).foregroundColor(.white).textCase(nil)
    }
}
