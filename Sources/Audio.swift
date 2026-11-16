
import AVFoundation
import Darwin
import Foundation

// MARK: - Audio Decoder

enum AudioDecoder {

    static func decode(url: URL) throws -> AVAudioPCMBuffer {
        if url.pathExtension.lowercased() == "ogg" {
            return try decodeOgg(url)
        }

        let file = try AVAudioFile(forReading: url)

        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw SimpleError("음원 버퍼를 만들 수 없어요")
        }

        try file.read(into: buffer)

        guard buffer.frameLength > 0 else {
            throw SimpleError("음원 데이터가 비어 있어요")
        }

        return buffer
    }

    static func decodeOgg(_ url: URL) throws -> AVAudioPCMBuffer {
        let data = try Data(contentsOf: url)

        guard !data.isEmpty, data.count <= Int(Int32.max) else {
            throw SimpleError("OGG 파일 크기가 올바르지 않아요")
        }

        var channels: Int32 = 0
        var sampleRate: Int32 = 0
        var pcm: UnsafeMutablePointer<Int16>?

        let frameCount: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }

            return stb_vorbis_decode_memory(
                base,
                Int32(data.count),
                &channels,
                &sampleRate,
                &pcm
            )
        }

        guard frameCount > 0,
              let pcm,
              channels > 0,
              sampleRate > 0 else {
            throw SimpleError("OGG 디코딩 실패")
        }

        defer {
            free(pcm)
        }

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channels),
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channelData = buffer.floatChannelData
        else {
            throw SimpleError("오디오 포맷 오류")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        let channelCount = Int(channels)
        let frames = Int(frameCount)

        for channel in 0..<channelCount {
            let destination = channelData[channel]

            for frame in 0..<frames {
                let sample = pcm[frame * channelCount + channel]
                destination[frame] = Float(sample) / 32768.0
            }
        }

        return buffer
    }
}


// MARK: - Shared Format

private enum AudioFormatKey {

    static func make(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))-\(format.channelCount)"
    }
}


// MARK: - Audio Session

private enum GameAudioSession {

    static func activate() throws {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playback,
            mode: .default,
            options: []
        )

        try session.setActive(true)
    }
}


// MARK: - SFX Pool

final class SfxPool {

    private let players: [AVAudioPlayerNode]
    private let buffer: AVAudioPCMBuffer

    private var index = 0

    init(
        engine: AVAudioEngine,
        buffer: AVAudioPCMBuffer,
        count: Int = 4
    ) {
        self.buffer = buffer

        var nodes: [AVAudioPlayerNode] = []

        for _ in 0..<max(1, count) {
            let player = AVAudioPlayerNode()

            engine.attach(player)

            engine.connect(
                player,
                to: engine.mainMixerNode,
                format: buffer.format
            )

            nodes.append(player)
        }

        players = nodes
    }

    func startAll() {
        // 재생할 버퍼가 있을 때만 각 노드를 시작한다.
    }

    func play() {
        guard !players.isEmpty else { return }

        let player = players[index]

        index = (index + 1) % players.count

        player.scheduleBuffer(
            buffer,
            at: nil,
            options: .interrupts,
            completionHandler: nil
        )

        if !player.isPlaying {
            player.play()
        }
    }

    func stopAll() {
        for player in players {
            player.stop()
        }
    }
}


// MARK: - Hit Synth

/// 돈 / 카 전용 저지연 렌더링 엔진.
/// AVAudioPlayerNode의 반복적인 예약 호출 대신
/// AVAudioSourceNode에서 샘플을 직접 믹싱한다.

final class HitSynth {

    private struct Voice {
        var sound: Int32 = 0
        var position: Int = 0
        var active: Bool = false
    }

    private struct Sound {
        var left: UnsafeMutablePointer<Float>
        var right: UnsafeMutablePointer<Float>
        var frames: Int
    }

    private static let maxVoices = 16

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let voices: UnsafeMutablePointer<Voice>
    private let sounds: UnsafeMutablePointer<Sound>

    private let soundCount: Int

    private var owned: [UnsafeMutablePointer<Float>] = []
    private var freed = false

    private(set) var node: AVAudioSourceNode!
    let format: AVAudioFormat

    init?(buffers: [AVAudioPCMBuffer]) {

        guard let first = buffers.first else {
            return nil
        }

        let format = first.format

        guard
            format.commonFormat == .pcmFormatFloat32,
            !format.isInterleaved,
            format.channelCount >= 1,
            format.channelCount <= 2
        else {
            return nil
        }

        for buffer in buffers {
            guard
                buffer.format.sampleRate == format.sampleRate,
                buffer.format.channelCount == format.channelCount,
                buffer.format.commonFormat == .pcmFormatFloat32,
                !buffer.format.isInterleaved,
                buffer.floatChannelData != nil,
                buffer.frameLength > 0
            else {
                return nil
            }
        }

        self.format = format
        self.soundCount = buffers.count

        lock = .allocate(capacity: 1)
        voices = .allocate(capacity: Self.maxVoices)
        sounds = .allocate(capacity: buffers.count)

        lock.initialize(to: os_unfair_lock())

        voices.initialize(
            repeating: Voice(),
            count: Self.maxVoices
        )

        for (index, buffer) in buffers.enumerated() {

            let frames = Int(buffer.frameLength)
            let channelData = buffer.floatChannelData!

            let left = UnsafeMutablePointer<Float>.allocate(
                capacity: frames
            )

            left.update(
                from: channelData[0],
                count: frames
            )

            owned.append(left)

            var right = left

            if format.channelCount == 2 {

                right = UnsafeMutablePointer<Float>.allocate(
                    capacity: frames
                )

                right.update(
                    from: channelData[1],
                    count: frames
                )

                owned.append(right)
            }

            (sounds + index).initialize(
                to: Sound(
                    left: left,
                    right: right,
                    frames: frames
                )
            )
        }

        let lockPointer = lock
        let voicePointer = voices
        let soundPointer = sounds
        let maxVoiceCount = Self.maxVoices

        node = AVAudioSourceNode(format: format) {
            _, _, frameCount, audioBufferList -> OSStatus in

            let output = UnsafeMutableAudioBufferListPointer(
                audioBufferList
            )

            let count = Int(frameCount)

            for channel in 0..<output.count {
                if let data = output[channel].mData {
                    memset(
                        data,
                        0,
                        count * MemoryLayout<Float>.size
                    )
                }
            }

            os_unfair_lock_lock(lockPointer)

            for voiceIndex in 0..<maxVoiceCount {

                guard voicePointer[voiceIndex].active else {
                    continue
                }

                let sound = soundPointer[
                    Int(voicePointer[voiceIndex].sound)
                ]

                let position = voicePointer[voiceIndex].position

                let remaining = sound.frames - position
                let length = min(count, remaining)

                if length > 0 {

                    for channel in 0..<output.count {

                        guard let destination = output[channel]
                            .mData?
                            .assumingMemoryBound(to: Float.self)
                        else {
                            continue
                        }

                        let source = (
                            channel == 0
                            ? sound.left
                            : sound.right
                        ) + position

                        for sample in 0..<length {
                            destination[sample] += source[sample]
                        }
                    }
                }

                voicePointer[voiceIndex].position += max(length, 0)

                if voicePointer[voiceIndex].position >= sound.frames {
                    voicePointer[voiceIndex].active = false
                }
            }

            os_unfair_lock_unlock(lockPointer)

            return noErr
        }
    }

    /// index: 초기화할 때 전달한 버퍼의 순서
    func trigger(_ index: Int) {

        guard
            index >= 0,
            index < soundCount,
            !freed
        else {
            return
        }

        os_unfair_lock_lock(lock)

        var slot = -1
        var oldest = -1
        var oldestPosition = -1

        for index in 0..<Self.maxVoices {

            if !voices[index].active {
                slot = index
                break
            }

            if voices[index].position > oldestPosition {
                oldestPosition = voices[index].position
                oldest = index
            }
        }

        if slot < 0 {
            slot = oldest
        }

        if slot >= 0 {
            voices[slot] = Voice(
                sound: Int32(index),
                position: 0,
                active: true
            )
        }

        os_unfair_lock_unlock(lock)
    }

    func reset() {

        guard !freed else { return }

        os_unfair_lock_lock(lock)

        for index in 0..<Self.maxVoices {
            voices[index].active = false
            voices[index].position = 0
        }

        os_unfair_lock_unlock(lock)
    }

    /// 반드시 오디오 엔진을 중지한 다음 호출
    func free() {

        guard !freed else { return }

        freed = true

        for pointer in owned {
            pointer.deallocate()
        }

        owned.removeAll()

        sounds.deinitialize(count: soundCount)
        sounds.deallocate()

        voices.deinitialize(count: Self.maxVoices)
        voices.deallocate()

        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}


// MARK: - Voice Bank

final class VoiceBank {

    private let buffers: [String: AVAudioPCMBuffer]

    private var nodes: [String: [AVAudioPlayerNode]] = [:]
    private var cursor: [String: Int] = [:]

    init(
        engine: AVAudioEngine,
        buffers: [String: AVAudioPCMBuffer]
    ) {

        self.buffers = buffers

        var formats: [String: AVAudioFormat] = [:]

        for buffer in buffers.values {
            let key = AudioFormatKey.make(buffer.format)
            formats[key] = buffer.format
        }

        for (key, format) in formats {

            var players: [AVAudioPlayerNode] = []

            for _ in 0..<2 {

                let player = AVAudioPlayerNode()

                engine.attach(player)

                engine.connect(
                    player,
                    to: engine.mainMixerNode,
                    format: format
                )

                players.append(player)
            }

            nodes[key] = players
        }
    }

    func play(_ name: String) {

        guard let buffer = buffers[name] else {
            return
        }

        let key = AudioFormatKey.make(buffer.format)

        guard
            let players = nodes[key],
            !players.isEmpty
        else {
            return
        }

        let index = cursor[key, default: 0]

        cursor[key] = (index + 1) % players.count

        let player = players[index]

        player.scheduleBuffer(
            buffer,
            at: nil,
            options: .interrupts,
            completionHandler: nil
        )

        if !player.isPlaying {
            player.play()
        }
    }

    func stopAll() {

        for players in nodes.values {
            for player in players {
                player.stop()
            }
        }
    }
}


// MARK: - Game Audio

/// 게임 음악 및 실시간 효과음 관리.
/// 곡의 시작 시각을 판정 기준 시계로 사용한다.

final class GameAudio {

    private let engine = AVAudioEngine()

    private let music = AVAudioPlayerNode()
    private let musicBuffer: AVAudioPCMBuffer

    private var don: SfxPool?
    private var ka: SfxPool?

    private var voices: VoiceBank?
    private var synth: HitSynth?

    private var isStarted = false
    private var isStopped = false

    private(set) var startUptime: Double = 0
    private(set) var latencyMs: Double = 0

    // MARK: Initialization

    init(
        music buffer: AVAudioPCMBuffer,
        extras: [String: AVAudioPCMBuffer] = [:]
    ) throws {

        guard buffer.frameLength > 0 else {
            throw SimpleError("음악 버퍼가 비어 있어요")
        }

        musicBuffer = buffer

        let session = AVAudioSession.sharedInstance()

        // 세션은 게임 시작 시 활성화한다.
        // 초기화 단계에서는 포맷과 노드만 구성한다.
        try? session.setPreferredIOBufferDuration(0.005)

        engine.attach(music)

        engine.connect(
            music,
            to: engine.mainMixerNode,
            format: buffer.format
        )

        var donBuffer: AVAudioPCMBuffer?
        var kaBuffer: AVAudioPCMBuffer?

        if let url = Bundle.main.url(
            forResource: "neiro_1_don",
            withExtension: "ogg"
        ) {
            donBuffer = try? AudioDecoder.decode(url: url)
        }

        if let url = Bundle.main.url(
            forResource: "neiro_1_ka",
            withExtension: "ogg"
        ) {
            kaBuffer = try? AudioDecoder.decode(url: url)
        }

        // 돈 / 카 샘플을 하나의 저지연 렌더 노드에서 처리한다.
        if
            let donBuffer,
            let kaBuffer,
            let hitSynth = HitSynth(
                buffers: [donBuffer, kaBuffer]
            )
        {

            engine.attach(hitSynth.node)

            engine.connect(
                hitSynth.node,
                to: engine.mainMixerNode,
                format: hitSynth.format
            )

            synth = hitSynth

        } else {

            // 포맷이 다르면 개별 노드 풀 사용
            if let donBuffer {
                don = SfxPool(
                    engine: engine,
                    buffer: donBuffer
                )
            }

            if let kaBuffer {
                ka = SfxPool(
                    engine: engine,
                    buffer: kaBuffer
                )
            }
        }

        voices = VoiceBank(
            engine: engine,
            buffers: extras
        )
    }

    // MARK: Start

    /// leadIn 초 뒤에 음악을 시작한다.
    func start(leadIn: Double = 1.5) {

        guard !isStarted else {
            return
        }

        guard !isStopped else {
            print("[GameAudio] Already stopped")
            return
        }

        guard leadIn >= 0 else {
            print("[GameAudio] Invalid lead-in")
            return
        }

        do {

            try GameAudioSession.activate()

            // 그래프 준비
            engine.prepare()

            // 이미 실행 중인 엔진은 재시작하지 않는다.
            if !engine.isRunning {
                try engine.start()
            }

            guard engine.isRunning else {
                print("[GameAudio] Engine is not running")
                return
            }

        } catch {

            print("[GameAudio] Engine start failed: \(error)")

            engine.stop()

            return
        }

        isStarted = true

        // 예약된 음악과 이전 효과음 상태 정리
        music.stop()

        synth?.reset()

        let startHost = mach_absolute_time()
            + AVAudioTime.hostTime(forSeconds: leadIn)

        // 음악 예약
        music.scheduleBuffer(
            musicBuffer,
            at: nil,
            options: [],
            completionHandler: nil
        )

        // 음악 시작 시각 예약
        music.play(
            at: AVAudioTime(hostTime: startHost)
        )

        startUptime = AVAudioTime.seconds(
            forHostTime: startHost
        )

        // 출력 지연 측정
        let session = AVAudioSession.sharedInstance()

        latencyMs = (
            session.outputLatency
            + session.ioBufferDuration
        ) * 1000

        print("[GameAudio] Started")
        print("[GameAudio] Latency: \(latencyMs) ms")
        print("[GameAudio] Lead-in: \(leadIn) sec")
    }

    // MARK: Voice

    /// 미리 디코딩된 음성을 재생한다.
    func play(_ name: String) {

        guard isStarted, engine.isRunning else {
            return
        }

        voices?.play(name)
    }

    // MARK: Hit SFX

    /// 돈 / 카 효과음
    func playSfx(don isDon: Bool) {

        guard isStarted, engine.isRunning else {
            return
        }

        if let synth {
            synth.trigger(isDon ? 0 : 1)
        } else {
            (isDon ? don : ka)?.play()
        }
    }

    // MARK: Stop

    func stop() {

        guard !isStopped else {
            return
        }

        isStopped = true
        isStarted = false

        // 음악 중지
        music.stop()

        // 음성 및 효과음 중지
        voices?.stopAll()

        don?.stopAll()
        ka?.stopAll()

        // 엔진 중지
        engine.stop()

        // 렌더링 중인 샘플 초기화
        synth?.reset()

        print("[GameAudio] Stopped")
    }

    // MARK: Decode Extras

    /// 게임 시작 전에 효과음을 미리 디코딩한다.
    static func decodeExtras(
        _ names: [String]
    ) -> [String: AVAudioPCMBuffer] {

        var result: [String: AVAudioPCMBuffer] = [:]

        for name in names {

            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "ogg"
            ) else {
                continue
            }

            if let buffer = try? AudioDecoder.decode(url: url) {
                result[name] = buffer
            }
        }

        return result
    }

    // MARK: Deinitialization

    deinit {

        if engine.isRunning {
            engine.stop()
        }

        synth?.free()
    }
}
