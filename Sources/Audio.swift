import AVFoundation
import Darwin

enum AudioDecoder {
    static func decode(url: URL) throws -> AVAudioPCMBuffer {
        if url.pathExtension.lowercased() == "ogg" { return try decodeOgg(url) }
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SimpleError("음원 버퍼를 만들 수 없어요")
        }
        try file.read(into: buf)
        return buf
    }

    static func decodeOgg(_ url: URL) throws -> AVAudioPCMBuffer {
        let data = try Data(contentsOf: url)
        var ch: Int32 = 0, sr: Int32 = 0
        var out: UnsafeMutablePointer<Int16>? = nil
        let n: Int32 = data.withUnsafeBytes { raw in
            stb_vorbis_decode_memory(raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &ch, &sr, &out)
        }
        guard n > 0, let pcm = out, ch > 0 else { throw SimpleError("ogg 디코딩 실패") }
        defer { free(pcm) }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sr),
                                      channels: AVAudioChannelCount(ch), interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
            throw SimpleError("오디오 포맷 오류")
        }
        buf.frameLength = AVAudioFrameCount(n)
        let channels = Int(ch), frames = Int(n)
        for c in 0..<channels {
            let dst = buf.floatChannelData![c]
            for i in 0..<frames { dst[i] = Float(pcm[i * channels + c]) / 32768.0 }
        }
        return buf
    }
}

final class SfxPool {
    private let players: [AVAudioPlayerNode]
    private let buffer: AVAudioPCMBuffer
    private var idx = 0

    init(engine: AVAudioEngine, buffer: AVAudioPCMBuffer, count: Int = 4) {
        self.buffer = buffer
        var ps: [AVAudioPlayerNode] = []
        for _ in 0..<count {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: buffer.format)
            ps.append(p)
        }
        players = ps
    }

    func startAll() { players.forEach { $0.play() } }

    func play() {
        let p = players[idx]
        idx = (idx + 1) % players.count
        p.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !p.isPlaying { p.play() }
    }
}

/// 타격음(돈/카) 전용 믹서. 타격할 때 AVAudioEngine 의 scheduleBuffer 를 부르지 않고,
/// 미리 복사해 둔 샘플을 오디오 스레드의 렌더 콜백이 직접 섞는다.
/// 메인 스레드는 "이 소리를 시작해라" 표시만 남기므로(잠금 몇 마이크로초) 연타해도 멈칫하지 않는다.
final class HitSynth {
    private struct Voice { var sound: Int32 = 0; var pos: Int = 0; var active: Bool = false }
    private struct Sound { var p0: UnsafeMutablePointer<Float>; var p1: UnsafeMutablePointer<Float>; var frames: Int }

    private static let maxVoices = 16
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let voices = UnsafeMutablePointer<Voice>.allocate(capacity: HitSynth.maxVoices)
    private let sounds: UnsafeMutablePointer<Sound>
    private let soundCount: Int
    private var owned: [UnsafeMutablePointer<Float>] = []
    private var freed = false
    private(set) var node: AVAudioSourceNode!
    let format: AVAudioFormat

    /// 모든 버퍼가 같은 포맷(float32, 1~2채널)일 때만 만들 수 있다. 아니면 nil.
    init?(buffers: [AVAudioPCMBuffer]) {
        guard let first = buffers.first else { return nil }
        let fmt = first.format
        guard fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved, fmt.channelCount >= 1, fmt.channelCount <= 2 else { return nil }
        for b in buffers where b.format.sampleRate != fmt.sampleRate || b.format.channelCount != fmt.channelCount || b.floatChannelData == nil { return nil }
        format = fmt
        soundCount = buffers.count
        sounds = UnsafeMutablePointer<Sound>.allocate(capacity: buffers.count)
        self.lock.initialize(to: os_unfair_lock())
        self.voices.initialize(repeating: Voice(), count: HitSynth.maxVoices)

        for (i, b) in buffers.enumerated() {
            let n = Int(b.frameLength)
            let data = b.floatChannelData!
            let p0 = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
            p0.update(from: data[0], count: n)
            owned.append(p0)
            var p1 = p0
            if fmt.channelCount == 2 {
                p1 = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
                p1.update(from: data[1], count: n)
                owned.append(p1)
            }
            (self.sounds + i).initialize(to: Sound(p0: p0, p1: p1, frames: n))
        }

        let lock = self.lock, voices = self.voices, sounds = self.sounds
        let maxV = HitSynth.maxVoices
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            for ci in 0..<list.count {
                if let d = list[ci].mData { memset(d, 0, n * MemoryLayout<Float>.size) }
            }
            os_unfair_lock_lock(lock)
            for v in 0..<maxV where voices[v].active {
                let snd = sounds[Int(voices[v].sound)]
                let m = min(n, snd.frames - voices[v].pos)
                if m > 0 {
                    for ci in 0..<list.count {
                        guard let out = list[ci].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        let src = (ci == 0 ? snd.p0 : snd.p1) + voices[v].pos
                        for i in 0..<m { out[i] += src[i] }
                    }
                }
                voices[v].pos += max(m, 0)
                if voices[v].pos >= snd.frames { voices[v].active = false }
            }
            os_unfair_lock_unlock(lock)
            return noErr
        }
    }

    /// index: 만들 때 넘긴 버퍼 순서
    func trigger(_ index: Int) {
        guard index >= 0, index < soundCount, !freed else { return }
        os_unfair_lock_lock(lock)
        var slot = -1, oldest = -1, oldestPos = -1
        for v in 0..<HitSynth.maxVoices {
            if !voices[v].active { slot = v; break }
            if voices[v].pos > oldestPos { oldestPos = voices[v].pos; oldest = v }
        }
        if slot < 0 { slot = oldest }          // 꽉 찼으면 가장 오래된 소리를 끊고 사용
        voices[slot] = Voice(sound: Int32(index), pos: 0, active: true)
        os_unfair_lock_unlock(lock)
    }

    /// 엔진을 멈춘 뒤에만 호출할 것
    func free() {
        guard !freed else { return }
        freed = true
        for p in owned { p.deallocate() }
        owned = []
        sounds.deallocate(); voices.deallocate(); lock.deallocate()
    }
}

/// 콤보 음성/풍선 효과음 묶음. 소리마다 노드를 하나씩 만들면 재생 중이 아닌 노드까지 오디오 스레드가
/// 계속 돌려서 부하가 커지고 터치 때 끊김이 생긴다 → 같은 포맷끼리 노드 2개를 공유한다.
final class VoiceBank {
    private let buffers: [String: AVAudioPCMBuffer]
    private var nodes: [String: [AVAudioPlayerNode]] = [:]
    private var cursor: [String: Int] = [:]

    private static func key(_ f: AVAudioFormat) -> String { "\(Int(f.sampleRate))-\(f.channelCount)" }

    init(engine: AVAudioEngine, buffers: [String: AVAudioPCMBuffer]) {
        self.buffers = buffers
        var formats: [String: AVAudioFormat] = [:]
        for b in buffers.values { formats[VoiceBank.key(b.format)] = b.format }
        for (k, f) in formats {
            var arr: [AVAudioPlayerNode] = []
            for _ in 0..<2 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: f)
                arr.append(p)
            }
            nodes[k] = arr
        }
    }

    func play(_ name: String) {
        guard let b = buffers[name] else { return }
        let k = VoiceBank.key(b.format)
        guard let arr = nodes[k], !arr.isEmpty else { return }
        let i = cursor[k, default: 0]
        cursor[k] = (i + 1) % arr.count
        let p = arr[i]
        p.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        if !p.isPlaying { p.play() }
    }
}

/// 음악 + 효과음. 곡 시작 시각(startUptime)을 정확히 알고 있어서 판정 기준 시계로 쓴다.
final class GameAudio {
    private let engine = AVAudioEngine()
    private let music = AVAudioPlayerNode()
    private let musicBuffer: AVAudioPCMBuffer
    private var don: SfxPool?
    private var ka: SfxPool?
    private var voices: VoiceBank?
    private var synth: HitSynth?

    private(set) var startUptime: Double = 0
    private(set) var latencyMs: Double = 0

    /// extras: 게임 중 쓸 효과음/음성을 미리 디코딩해서 넘긴다 (게임 중 디코딩하면 끊김)
    init(music buffer: AVAudioPCMBuffer, extras: [String: AVAudioPCMBuffer] = [:]) throws {
        musicBuffer = buffer
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setPreferredIOBufferDuration(0.005)
        try? s.setActive(true)

        engine.attach(music)
        engine.connect(music, to: engine.mainMixerNode, format: buffer.format)
        var donBuf: AVAudioPCMBuffer?, kaBuf: AVAudioPCMBuffer?
        if let u = Bundle.main.url(forResource: "neiro_1_don", withExtension: "ogg") { donBuf = try? AudioDecoder.decode(url: u) }
        if let u = Bundle.main.url(forResource: "neiro_1_ka", withExtension: "ogg") { kaBuf = try? AudioDecoder.decode(url: u) }
        if let d = donBuf, let k = kaBuf, let sy = HitSynth(buffers: [d, k]) {
            engine.attach(sy.node)
            engine.connect(sy.node, to: engine.mainMixerNode, format: sy.format)
            synth = sy
        } else {   // 포맷이 달라 합칠 수 없으면 예전 방식(노드 풀)으로
            if let b = donBuf { don = SfxPool(engine: engine, buffer: b) }
            if let b = kaBuf { ka = SfxPool(engine: engine, buffer: b) }
        }
        voices = VoiceBank(engine: engine, buffers: extras)
    }

    /// 미리 만들어 둔 풀로 재생 (없으면 무시)
    func play(_ name: String) { voices?.play(name) }

    /// 필요한 효과음을 백그라운드에서 미리 디코딩하기 위한 헬퍼
    static func decodeExtras(_ names: [String]) -> [String: AVAudioPCMBuffer] {
        var out: [String: AVAudioPCMBuffer] = [:]
        for n in names {
            if let u = Bundle.main.url(forResource: n, withExtension: "ogg"), let b = try? AudioDecoder.decode(url: u) { out[n] = b }
        }
        return out
    }

    /// leadIn 초 뒤에 곡이 시작되도록 예약한다.
    func start(leadIn: Double = 1.5) {
        do { try engine.start() } catch { return }
        don?.startAll(); ka?.startAll()
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadIn)
        music.scheduleBuffer(musicBuffer, at: nil, options: [], completionHandler: nil)
        music.play(at: AVAudioTime(hostTime: startHost))
        startUptime = AVAudioTime.seconds(forHostTime: startHost)
        let s = AVAudioSession.sharedInstance()
        latencyMs = (s.outputLatency + s.ioBufferDuration) * 1000
    }

    func playSfx(don isDon: Bool) {
        if let sy = synth { sy.trigger(isDon ? 0 : 1) } else { (isDon ? don : ka)?.play() }
    }

    func stop() {
        music.stop()
        engine.stop()
    }

    deinit {
        if engine.isRunning { engine.stop() }
        synth?.free()
    }
}
