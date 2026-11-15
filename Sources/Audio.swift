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

/// 음악 + 효과음. 곡 시작 시각(startUptime)을 정확히 알고 있어서 판정 기준 시계로 쓴다.
final class GameAudio {
    private let engine = AVAudioEngine()
    private let music = AVAudioPlayerNode()
    private let musicBuffer: AVAudioPCMBuffer
    private var don: SfxPool?
    private var ka: SfxPool?
    var drumSoundsEnabled = true

    private(set) var startUptime: Double = 0
    private(set) var latencyMs: Double = 0

    init(music buffer: AVAudioPCMBuffer) throws {
        musicBuffer = buffer
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setPreferredIOBufferDuration(0.005)
        try? s.setActive(true)

        engine.attach(music)
        engine.connect(music, to: engine.mainMixerNode, format: buffer.format)
        let donURL = Bundle.main.url(forResource: "se_don", withExtension: "ogg", subdirectory: "Original/audio")
            ?? Bundle.main.url(forResource: "se_don", withExtension: "ogg")
            ?? Bundle.main.url(forResource: "neiro_1_don", withExtension: "ogg")
        let kaURL = Bundle.main.url(forResource: "se_ka", withExtension: "ogg", subdirectory: "Original/audio")
            ?? Bundle.main.url(forResource: "se_ka", withExtension: "ogg")
            ?? Bundle.main.url(forResource: "neiro_1_ka", withExtension: "ogg")
        if let u = donURL, let b = try? AudioDecoder.decode(url: u) { don = SfxPool(engine: engine, buffer: b) }
        if let u = kaURL, let b = try? AudioDecoder.decode(url: u) { ka = SfxPool(engine: engine, buffer: b) }
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

    func playSfx(don isDon: Bool) { guard drumSoundsEnabled else { return }; (isDon ? don : ka)?.play() }

    func stop() {
        music.stop()
        engine.stop()
    }
}


enum AudioDiagnostics {
    static var reportedOutputLatencyMs: Double {
        let session = AVAudioSession.sharedInstance()
        return (session.outputLatency + session.ioBufferDuration) * 1000
    }

    static var currentOutputName: String {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        return names.isEmpty ? "알 수 없음" : names.joined(separator: ", ")
    }
}
