import AVFoundation

/// 곡 목록에서 길게 눌러 듣는 미리듣기 (하이라이트 구간 약 20초)
/// - 서버가 준 preview(초) 가 있으면 그 지점, 없으면 음원에서 소리가 가장 큰 20초 구간을 고른다.
@MainActor
final class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()

    @Published private(set) var playingKey: String?
    @Published private(set) var loadingKey: String?

    private let engine = AVAudioEngine()
    private var current: AVAudioPlayerNode?
    private var token = 0

    /// 같은 곡을 다시 누르면 정지
    func toggle(key: String, startSec: Double?, load: @escaping () async -> URL?) {
        if playingKey == key || loadingKey == key { stop(); return }
        stop(resumeBgm: false)
        Bgm.shared.stop()
        token += 1
        let my = token
        loadingKey = key
        Task {
            guard let url = await load() else {
                if my == token { loadingKey = nil; Bgm.shared.play("bgm_songsel") }
                return
            }
            let seg = await Task.detached(priority: .userInitiated) {
                PreviewPlayer.makeSegment(url: url, startSec: startSec)
            }.value
            guard my == token else { return }
            guard let seg else { loadingKey = nil; Bgm.shared.play("bgm_songsel"); return }
            play(seg, key: key, token: my)
        }
    }

    private func play(_ buf: AVAudioPCMBuffer, key: String, token my: Int) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buf.format)
        if !engine.isRunning { try? engine.start() }
        current = node
        node.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                if let self, self.token == my { self.stop() }
            }
        }
        node.play()
        loadingKey = nil
        playingKey = key
    }

    func stop(resumeBgm: Bool = true) {
        token += 1
        if let n = current { n.stop(); engine.detach(n); current = nil }
        if engine.isRunning { engine.stop() }
        let was = playingKey != nil || loadingKey != nil
        playingKey = nil; loadingKey = nil
        if resumeBgm && was { Bgm.shared.play("bgm_songsel") }
    }

    /// 음원 전체를 디코딩해서 20초 구간(앞 0.4초 페이드인, 뒤 1.5초 페이드아웃)만 잘라 낸다.
    nonisolated static func makeSegment(url: URL, startSec: Double?) -> AVAudioPCMBuffer? {
        guard let full = try? AudioDecoder.decode(url: url), let data = full.floatChannelData else { return nil }
        let sr = full.format.sampleRate
        let total = Int(full.frameLength)
        let chs = Int(full.format.channelCount)
        let want = Int(20 * sr)
        guard total > 0, chs > 0 else { return nil }

        var start = 0
        if let s = startSec, s > 0, Int(s * sr) < total - Int(2 * sr) {
            start = Int(s * sr)
        } else if total > want {
            let block = Int(0.5 * sr)
            let nb = total / block
            let win = 40
            if nb > win {
                var e = [Double](repeating: 0, count: nb)
                for b in 0..<nb {
                    var sum = 0.0
                    var i = b * block
                    let hi = i + block
                    while i < hi { let v = Double(data[0][i]); sum += v * v; i += 8 }
                    e[b] = sum
                }
                var cur = e[0..<win].reduce(0, +)
                var best = cur, bi = 0
                for i in 1...(nb - win) {
                    cur += e[i + win - 1] - e[i - 1]
                    if cur > best { best = cur; bi = i }
                }
                start = bi * block
            }
        }

        let len = min(want, total - start)
        guard len > 0,
              let out = AVAudioPCMBuffer(pcmFormat: full.format, frameCapacity: AVAudioFrameCount(len)),
              let dstData = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(len)
        let fadeIn = max(1, Int(0.4 * sr)), fadeOut = max(1, Int(1.5 * sr))
        for c in 0..<chs {
            let src = data[c], dst = dstData[c]
            for i in 0..<len {
                var g: Float = 1
                if i < fadeIn { g = Float(i) / Float(fadeIn) }
                if i > len - fadeOut { g = min(g, Float(len - i) / Float(fadeOut)) }
                dst[i] = src[start + i] * g
            }
        }
        return out
    }
}
