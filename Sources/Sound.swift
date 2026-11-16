
import AVFoundation
import UIKit

// MARK: - Shared Audio Session

enum SharedAudioSession {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

// MARK: - Sound Effects

final class Sfx {
    static let shared = Sfx()

    private let engine = AVAudioEngine()
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var pools: [String: [AVAudioPlayerNode]] = [:]
    private var cursor: [String: Int] = [:]
    private var loading: [String: Float] = [:]

    private var sessionReady = false
    private var suspended = false
    private var starting = false

    private let decodeQueue = DispatchQueue(
        label: "taikoi.sfx.decode",
        qos: .userInitiated
    )

    private func formatKey(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))-\(f.channelCount)"
    }

    private func prepareSession() -> Bool {
        if sessionReady { return true }

        do {
            try SharedAudioSession.activate()
            sessionReady = true
            return true
        } catch {
            print("[SFX] Audio session activation failed: \(error)")
            sessionReady = false
            return false
        }
    }

    private func pool(for format: AVAudioFormat) -> [AVAudioPlayerNode] {
        let key = formatKey(format)

        if let existing = pools[key] {
            return existing
        }

        var nodes: [AVAudioPlayerNode] = []

        for _ in 0..<4 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(
                node,
                to: engine.mainMixerNode,
                format: format
            )
            nodes.append(node)
        }

        pools[key] = nodes
        return nodes
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        guard !suspended else { return false }
        guard !starting else { return false }
        guard !engine.isRunning else { return true }

        starting = true
        defer { starting = false }

        guard prepareSession() else { return false }

        do {
            engine.prepare()
            try engine.start()

            print("[SFX] Engine started")
            return true
        } catch {
            print("[SFX] Engine start failed: \(error)")
            engine.stop()
            sessionReady = false
            return false
        }
    }

    func preload(_ names: [String]) {
        decodeQueue.async { [weak self] in
            guard let self else { return }

            var decoded: [(String, AVAudioPCMBuffer)] = []

            for name in names {
                guard
                    let url = Bundle.main.url(
                        forResource: name,
                        withExtension: "ogg"
                    ),
                    let buffer = try? AudioDecoder.decode(url: url)
                else {
                    continue
                }

                decoded.append((name, buffer))
            }

            DispatchQueue.main.async {
                for (name, buffer) in decoded {
                    if self.cache[name] == nil {
                        self.cache[name] = buffer
                        _ = self.pool(for: buffer.format)
                    }
                }

                self.startEngineIfNeeded()

                let pending = self.loading
                self.loading.removeAll()

                for (name, volume) in pending {
                    if self.cache[name] != nil {
                        self.play(name, volume: volume)
                    }
                }
            }
        }
    }

    func play(_ name: String, volume: Float = 1) {
        guard !suspended else { return }

        guard let buffer = cache[name] else {
            guard loading[name] == nil else { return }

            loading[name] = volume

            decodeQueue.async { [weak self] in
                guard let self else { return }

                guard
                    let url = Bundle.main.url(
                        forResource: name,
                        withExtension: "ogg"
                    ),
                    let buffer = try? AudioDecoder.decode(url: url)
                else {
                    DispatchQueue.main.async {
                        self.loading[name] = nil
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.cache[name] = buffer
                    _ = self.pool(for: buffer.format)

                    let requestedVolume = self.loading.removeValue(
                        forKey: name
                    )

                    if let requestedVolume {
                        self.play(name, volume: requestedVolume)
                    }
                }
            }

            return
        }

        guard startEngineIfNeeded() else { return }

        let nodes = pool(for: buffer.format)
        guard !nodes.isEmpty else { return }

        let key = formatKey(buffer.format)
        let index = cursor[key, default: 0]

        cursor[key] = (index + 1) % nodes.count

        let node = nodes[index]
        node.volume = volume
        node.scheduleBuffer(
            buffer,
            at: nil,
            options: .interrupts,
            completionHandler: nil
        )

        if !node.isPlaying {
            node.play()
        }
    }

    func suspend() {
        guard !suspended else { return }

        suspended = true
        sessionReady = false
        loading.removeAll()

        for nodes in pools.values {
            for node in nodes {
                node.stop()
            }
        }

        engine.stop()
    }

    func resume() {
        guard suspended else { return }

        suspended = false

        guard startEngineIfNeeded() else {
            suspended = true
            return
        }
    }
}

// MARK: - Background Music

final class Bgm {
    static let shared = Bgm()

    private var player: AVAudioPlayer?
    private var playerName: String?
    private var wanted: String?
    private var suspended = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "bgmOn") as? Bool ?? true
    }

    func prewarm(_ name: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard
                let url = Bundle.main.url(
                    forResource: name,
                    withExtension: "mp3"
                ),
                let player = try? AVAudioPlayer(contentsOf: url)
            else {
                return
            }

            player.numberOfLoops = -1
            player.volume = 0.6
            player.prepareToPlay()

            DispatchQueue.main.async {
                guard let self, self.player == nil else { return }

                self.player = player
                self.playerName = name
            }
        }
    }

    @discardableResult
    private func activateSession() -> Bool {
        do {
            try SharedAudioSession.activate()
            return true
        } catch {
            print("[BGM] Session activation failed: \(error)")
            return false
        }
    }

    func play(_ name: String) {
        wanted = name

        guard Bgm.enabled, !suspended else { return }
        guard activateSession() else { return }

        if playerName == name, let player {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        player?.stop()
        player = nil
        playerName = nil

        guard
            let url = Bundle.main.url(
                forResource: name,
                withExtension: "mp3"
            ),
            let newPlayer = try? AVAudioPlayer(contentsOf: url)
        else {
            return
        }

        newPlayer.numberOfLoops = -1
        newPlayer.volume = 0.6
        newPlayer.prepareToPlay()

        guard newPlayer.play() else { return }

        player = newPlayer
        playerName = name
    }

    func stop() {
        wanted = nil
        player?.pause()
    }

    func setEnabled(_ on: Bool, track: String = "bgm_songsel") {
        if on {
            play(track)
        } else {
            player?.pause()
        }
    }

    func suspend() {
        guard !suspended else { return }

        suspended = true
        player?.pause()
    }

    func resume() {
        guard suspended else { return }

        suspended = false

        guard Bgm.enabled, let name = wanted else { return }
        play(name)
    }
}

// MARK: - Application Audio Lifecycle

enum AppAudio {
    private static var isActive = false

    static func enterBackground() {
        guard isActive else { return }

        isActive = false

        Bgm.shared.suspend()
        Sfx.shared.suspend()

        Task { @MainActor in
            PreviewPlayer.shared.stop(resumeBgm: false)
        }

        SharedAudioSession.deactivate()
    }

    static func becomeActive() {
        guard !isActive else { return }

        isActive = true

        Sfx.shared.resume()
        Bgm.shared.resume()

        SystemGuard.applyRepeatedly()
    }
}
