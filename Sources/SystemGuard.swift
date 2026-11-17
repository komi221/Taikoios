import UIKit
import SpriteKit

/// 세 손가락 터치/스와이프 때 iOS 가 띄우는 복사·붙여넣기·실행취소 막대를 막는다.
/// 시스템 뷰(검색창, 상단바 등)를 건드리면 앱이 튕길 수 있어서, 윈도우에 붙은
/// 편집 제스처 한 종류만 끈다. 인터랙션 제거나 하위 뷰 순회는 하지 않는다.
enum SystemGuard {
    static func apply() {
        DispatchQueue.main.async {
            UIApplication.shared.applicationSupportsShakeToEdit = false
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows {
                    for g in w.gestureRecognizers ?? [] {
                        let n = NSStringFromClass(type(of: g))
                        if n.contains("EditingOverlay") || n.contains("UndoGesture") { g.isEnabled = false }
                    }
                }
            }
        }
    }

    static func applyRepeatedly() {
        apply()
        for d in [0.3, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { apply() }
        }
    }
}

/// 게임 화면용 SKView: 편집 메뉴/실행취소를 아예 받지 않는다.
final class GameSKViewHost: SKView {
    /// 0이면 기기 기본값. 값을 낮추면 화면을 그리는 해상도(contentScaleFactor)가 줄어 그리는 양이 준다.
    var renderScale: CGFloat = 0 { didSet { applyRenderScale() } }
    private func applyRenderScale() {
        guard renderScale > 0, abs(contentScaleFactor - renderScale) > 0.01 else { return }
        contentScaleFactor = renderScale
    }
    override func didMoveToWindow() { super.didMoveToWindow(); applyRenderScale() }
    override func layoutSubviews() { super.layoutSubviews(); applyRenderScale() }

    override var canBecomeFirstResponder: Bool { false }
    override var undoManager: UndoManager? { nil }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
