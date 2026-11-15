import UIKit
import SpriteKit

/// 세 손가락 터치/스와이프 때 iOS 가 띄우는 복사·붙여넣기·실행취소 막대를 막는다.
/// 시스템이 윈도우에 붙여 둔 편집 제스처만 찾아서 꺼 준다 (게임 입력에는 영향 없음).
enum SystemGuard {
    private static let needles = ["EditingOverlay", "UndoGesture", "EditMenu", "ShortcutBar"]

    static func apply() {
        DispatchQueue.main.async {
            UIApplication.shared.applicationSupportsShakeToEdit = false
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows { strip(w) }
            }
        }
    }

    /// 제스처가 늦게 붙는 경우가 있어서 몇 번에 나눠 다시 적용
    static func applyRepeatedly() {
        apply()
        for d in [0.3, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { apply() }
        }
    }

    private static func strip(_ v: UIView) {
        for g in v.gestureRecognizers ?? [] {
            let n = NSStringFromClass(type(of: g))
            if needles.contains(where: { n.contains($0) }) { g.isEnabled = false }
        }
        for i in v.interactions {
            let n = NSStringFromClass(type(of: i))
            if needles.contains(where: { n.contains($0) }) { v.removeInteraction(i) }
        }
        for s in v.subviews { strip(s) }
    }
}

/// 게임 화면용 SKView: 편집 메뉴/실행취소를 아예 받지 않는다.
final class GameSKViewHost: SKView {
    override var canBecomeFirstResponder: Bool { false }
    override var undoManager: UndoManager? { nil }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
