import AVFoundation

/// 메뉴용 효과음 (ogg 는 stb_vorbis 로 디코딩)
final class Sfx {
    static let shared = Sfx()
    private let engine = AVAudioEngine()
    private var cache: [String: AVAudioPCMBuffer] = [:]

    /// 메뉴/결과 화면에서 쓸 소리를 미리 디코딩 (처음 재생할 때 끊기지 않게)
    func preload(_ names: [String]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for n in names {
                guard let u = Bundle.main.url(forResource: n, withExtension: "ogg"),
                      let b = try? AudioDecoder.decode(url: u) else { continue }
                DispatchQueue.main.async { if self?.cache[n] == nil { self?.cache[n] = b } }
            }
        }
    }

    func play(_ name: String, volume: Float = 1) {
        let buf: AVAudioPCMBuffer
        if let c = cache[name] { buf = c }
        else {
            guard let u = Bundle.main.url(forResource: name, withExtension: "ogg"),
                  let b = try? AudioDecoder.decode(url: u) else { return }
            cache[name] = b; buf = b
        }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buf.format)
        if !engine.isRunning { try? engine.start() }
        node.volume = volume
        node.scheduleBuffer(buf, at: nil, options: []) { [weak self, weak node] in
            DispatchQueue.main.async {
                if let n = node { n.stop(); self?.engine.detach(n) }
            }
        }
        node.play()
    }
}

/// 곡 선택 BGM (mp3)
final class Bgm {
    static let shared = Bgm()
    private var player: AVAudioPlayer?

    func play(_ name: String) {
        if player?.isPlaying == true { return }
        guard let u = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        player = try? AVAudioPlayer(contentsOf: u)
        player?.numberOfLoops = -1
        player?.volume = 0.6
        player?.play()
    }

    func stop() { player?.stop(); player = nil }
}
