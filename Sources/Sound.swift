import AVFoundation
import UIKit

/// 메뉴용 효과음 (ogg 는 stb_vorbis 로 디코딩)
/// - 플레이어 노드를 미리 만들어 돌려 쓴다 (재생할 때마다 노드를 붙였다 떼면 오디오 그래프가 재구성돼서 멈칫함)
/// - 디코딩은 항상 백그라운드, 오디오 세션 설정도 처음 한 번만
final class Sfx {
    static let shared = Sfx()
    private let engine = AVAudioEngine()
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var pools: [String: [AVAudioPlayerNode]] = [:]
    private var cursor: [String: Int] = [:]
    private var loading: [String: Float] = [:]      // 디코딩 중인 이름 → 끝나면 바로 재생할 음량
    private var sessionReady = false
    private var suspended = false
    private let decodeQueue = DispatchQueue(label: "taikoi.sfx.decode", qos: .userInitiated)

    private func formatKey(_ f: AVAudioFormat) -> String { "\(Int(f.sampleRate))-\(f.channelCount)" }

    private func prepareSession() {
        guard !sessionReady else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        sessionReady = true
    }

    private func pool(for f: AVAudioFormat) -> [AVAudioPlayerNode] {
        let k = formatKey(f)
        if let p = pools[k] { return p }
        var arr: [AVAudioPlayerNode] = []
        for _ in 0..<4 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: f)
            arr.append(n)
        }
        pools[k] = arr
        return arr
    }

    private func startEngineIfNeeded() {
        guard !suspended else { return }
        if !engine.isRunning { prepareSession(); try? engine.start() }
    }

    /// 메뉴/결과 화면에서 쓸 소리를 미리 디코딩하고 엔진도 미리 켜 둔다 (처음 재생할 때 끊기지 않게)
    func preload(_ names: [String]) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.prepareSession()
            var done: [(String, AVAudioPCMBuffer)] = []
            for n in names {
                guard let u = Bundle.main.url(forResource: n, withExtension: "ogg"),
                      let b = try? AudioDecoder.decode(url: u) else { continue }
                done.append((n, b))
            }
            DispatchQueue.main.async {
                for (n, b) in done where self.cache[n] == nil {
                    self.cache[n] = b
                    _ = self.pool(for: b.format)
                }
                self.startEngineIfNeeded()
                // 디코딩을 기다리던 재생 요청 처리
                for (n, vol) in self.loading where self.cache[n] != nil {
                    self.loading[n] = nil
                    self.play(n, volume: vol)
                }
            }
        }
    }

    func play(_ name: String, volume: Float = 1) {
        guard !suspended else { return }
        guard let buf = cache[name] else {
            // 아직 디코딩 전: 메인 스레드에서 디코딩하지 않고 백그라운드에서 끝나면 재생
            if loading[name] == nil {
                loading[name] = volume
                decodeQueue.async { [weak self] in
                    guard let self else { return }
                    self.prepareSession()
                    guard let u = Bundle.main.url(forResource: name, withExtension: "ogg"),
                          let b = try? AudioDecoder.decode(url: u) else {
                        DispatchQueue.main.async { self.loading[name] = nil }
                        return
                    }
                    DispatchQueue.main.async {
                        self.cache[name] = b
                        _ = self.pool(for: b.format)
                        let v = self.loading[name]
                        self.loading[name] = nil
                        self.startEngineIfNeeded()
                        if let v { self.play(name, volume: v) }
                    }
                }
            }
            return
        }
        startEngineIfNeeded()
        let nodes = pool(for: buf.format)
        let k = formatKey(buf.format)
        let i = cursor[k, default: 0]
        cursor[k] = (i + 1) % nodes.count
        let node = nodes[i]
        node.volume = volume
        node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    /// 앱이 백그라운드로 가면 소리를 완전히 끊는다
    func suspend() {
        suspended = true
        sessionReady = false
        for arr in pools.values { for n in arr { n.stop() } }
        if engine.isRunning { engine.stop() }
    }

    func resume() {
        suspended = false
        startEngineIfNeeded()
    }
}

/// 곡 선택 BGM (mp3)
/// - 설정의 "메인 화면 배경음악" 스위치(bgmOn)를 따른다
/// - 앱이 백그라운드에 있는 동안은 멈추고, 돌아오면 이어서 재생
final class Bgm {
    static let shared = Bgm()
    private var player: AVAudioPlayer?
    private var playerName: String?
    private var wanted: String?          // 지금 틀어야 하는 곡 (스위치/백그라운드 때문에 못 틀고 있어도 기억)
    private var suspended = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: "bgmOn") as? Bool ?? true }

    /// mp3 를 미리 열어 둔다 (처음 재생할 때 화면 전환이 끊기지 않게)
    func prewarm(_ name: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let u = Bundle.main.url(forResource: name, withExtension: "mp3"),
                  let p = try? AVAudioPlayer(contentsOf: u) else { return }
            p.numberOfLoops = -1
            p.volume = 0.6
            p.prepareToPlay()
            DispatchQueue.main.async {
                guard let self, self.player == nil else { return }
                self.player = p; self.playerName = name
            }
        }
    }

    func play(_ name: String) {
        wanted = name
        guard Bgm.enabled, !suspended else { return }
        if playerName == name, let p = player {
            if !p.isPlaying { activateSession(); p.play() }
            return
        }
        player?.stop(); player = nil; playerName = nil
        guard let u = Bundle.main.url(forResource: name, withExtension: "mp3"),
              let p = try? AVAudioPlayer(contentsOf: u) else { return }
        activateSession()
        p.numberOfLoops = -1
        p.volume = 0.6
        p.play()
        player = p; playerName = name
    }

    /// 의도적으로 멈춤 (게임 시작, 미리듣기 등)
    func stop() {
        wanted = nil
        player?.pause()          // 닫지 않고 멈춰만 둬서 다음에 바로 이어 재생
    }

    /// 설정 스위치 변경
    func setEnabled(_ on: Bool, track: String = "bgm_songsel") {
        if on { play(track) } else { player?.pause() }
    }

    func suspend() {
        suspended = true
        player?.pause()
    }

    func resume() {
        suspended = false
        guard Bgm.enabled, let n = wanted else { return }
        play(n)
    }

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
    }
}

/// 앱이 화면에서 사라질 때 모든 소리를 끊고, 돌아오면 필요한 것만 다시 켠다.
enum AppAudio {
    static func enterBackground() {
        Bgm.shared.suspend()
        Sfx.shared.suspend()
        Task { @MainActor in PreviewPlayer.shared.stop(resumeBgm: false) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func becomeActive() {
        Sfx.shared.resume()
        Bgm.shared.resume()
        SystemGuard.applyRepeatedly()
    }
}

