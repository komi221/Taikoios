import SpriteKit
import SwiftUI
import UIKit
import CoreText
import CoreGraphics

/// 원본 taiko-web 이미지/폰트 로더 (Resources 루트에 평평하게 들어있음)
enum Gfx {
    private static var cache: [String: UIImage] = [:]

    static func image(_ name: String) -> UIImage? {
        if let c = cache[name] { return c }
        guard let u = Bundle.main.url(forResource: name, withExtension: "png"),
              let im = UIImage(contentsOfFile: u.path) else { return nil }
        cache[name] = im
        return im
    }

    private static var texCache: [String: SKTexture] = [:]

    /// 같은 이미지는 텍스처를 한 번만 만든다 (매번 SKTexture(image:) 하면 GPU 업로드가 반복돼 끊김의 원인이 됨)
    static func texture(_ name: String) -> SKTexture {
        if let t = texCache[name] { return t }
        guard let im = image(name) else { return SKTexture() }
        let t = SKTexture(image: im)
        texCache[name] = t
        return t
    }

    /// 이미지 픽셀 좌표(좌상단 기준)로 잘라낸 텍스처 (부모 텍스처 공유)
    static func crop(_ name: String, _ r: CGRect) -> SKTexture {
        guard let im = image(name) else { return SKTexture() }
        let w = im.size.width, h = im.size.height
        let base = texture(name)
        return SKTexture(rect: CGRect(x: r.minX / w, y: 1 - r.maxY / h, width: r.width / w, height: r.height / h), in: base)
    }

    static func texture(from image: UIImage) -> SKTexture { SKTexture(image: image) }

    static func cropImage(_ name: String, _ r: CGRect) -> UIImage? {
        guard let cg = image(name)?.cgImage?.cropping(to: r) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func renderer(_ size: CGSize, scale: CGFloat = 1) -> UIGraphicsImageRenderer {
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale; f.opaque = false
        return UIGraphicsImageRenderer(size: size, format: f)
    }
}

enum Fonts {
    static var tnt = "Helvetica-Bold"
    static var kozuka = "Helvetica"

    static func register() {
        func reg(_ file: String, _ ext: String) -> String? {
            guard let u = Bundle.main.url(forResource: file, withExtension: ext) else { return nil }
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
            if let p = CGDataProvider(url: u as CFURL), let f = CGFont(p), let n = f.postScriptName { return n as String }
            return nil
        }
        if let n = reg("TnT", "ttf") { tnt = n }
        if let n = reg("Kozuka", "otf") { kozuka = n }
    }

    static func tntFont(_ size: CGFloat) -> UIFont { UIFont(name: tnt, size: size) ?? .boldSystemFont(ofSize: size) }
    static func kozukaFont(_ size: CGFloat) -> UIFont { UIFont(name: kozuka, size: size) ?? .systemFont(ofSize: size) }
}

/// 테두리 있는 글자 (원본의 strokeText + fillText)
func strokedText(_ s: String, font: UIFont, fill: UIColor = .white, stroke: UIColor = .black,
                 width: CGFloat = 6, align: NSTextAlignment = .center) -> NSAttributedString {
    let p = NSMutableParagraphStyle(); p.alignment = align
    return NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: fill, .strokeColor: stroke, .strokeWidth: -width, .paragraphStyle: p
    ])
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

extension UIColor {
    convenience init(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                  blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
