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

#if swift(>=5.9)
import Metal
import QuartzCore

/// SpriteKit 장면을 SKView 대신 직접 그리는 호스트 (실험적 "새 방식", iOS 17 이상).
/// CAMetalDisplayLink 가 알려 주는 '화면에 나갈 시각'에 맞춰 프레임을 만들고, 장면은 SKRenderer 로 그대로 그린다.
/// 장면 내용(디자인)은 SKView 때와 완전히 같다.
@available(iOS 17.0, *)
final class MetalGameHost: UIView, CAMetalDisplayLinkDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SKRenderer
    private let gameScene: GameScene
    private let fps: Int
    private var link: CAMetalDisplayLink?

    /// 0이면 기기 기본값. 값을 낮추면 그리는 해상도가 줄어든다.
    var renderScale: CGFloat = 0 { didSet { applyScale() } }

    init(scene: GameScene, fps: Int) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            fatalError("Metal 을 사용할 수 없는 기기입니다")
        }
        device = dev
        queue = q
        renderer = SKRenderer(device: dev)
        gameScene = scene
        self.fps = fps
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        renderer.ignoresSiblingOrder = true
        renderer.scene = scene
        scene.frameRateHint = fps
        scene.setupScene()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 는 쓰지 않습니다") }

    private func applyScale() {
        let s = renderScale > 0 ? renderScale : (window?.screen.scale ?? UIScreen.main.scale)
        if abs(contentScaleFactor - s) > 0.01 { contentScaleFactor = s }
        let size = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        gameScene.renderSizeHint = size
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyScale()
        if window != nil { startLink() } else { stop() }
    }
    override func layoutSubviews() { super.layoutSubviews(); applyScale() }

    private func startLink() {
        guard link == nil else { return }
        let l = CAMetalDisplayLink(metalLayer: metalLayer)
        l.delegate = self
        l.preferredFrameLatency = 2
        let hi = Float(max(30, fps))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: hi >= 100 ? 80 : hi, maximum: hi, preferred: hi)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        gameScene.externalPresentTime = update.targetPresentationTimestamp      // 이번 프레임이 화면에 나갈 시각
        renderer.update(atTime: update.targetTimestamp)                          // 장면의 update·액션 실행

        let drawable = update.drawable
        guard let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let viewport = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        renderer.render(withViewport: viewport, commandBuffer: cb, renderPassDescriptor: pass)
        cb.present(drawable)
        cb.commit()
    }

    // 터치: 화면 좌표를 장면 좌표(원점 왼쪽 아래)로 바꿔서 장면에 넘긴다
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let sz = gameScene.size
        for t in touches {
            let loc = t.location(in: self)
            let p = CGPoint(x: loc.x / w * sz.width, y: (1 - loc.y / h) * sz.height)
            gameScene.registerTap(scenePoint: p, uptime: t.timestamp)
        }
    }

    override var canBecomeFirstResponder: Bool { false }
    override var undoManager: UndoManager? { nil }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
#endif
