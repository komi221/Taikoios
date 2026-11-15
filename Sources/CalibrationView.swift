import SwiftUI
import AVFoundation
import AudioToolbox

/// Taiko Web의 40회 오디오/화면 보정 흐름을 참고한 네이티브 캘리브레이션.
@MainActor
final class CalibrationSession: ObservableObject {
    enum Stage {
        case intro, audio, audioDone, video, videoDone
    }

    @Published private(set) var stage: Stage = .intro
    @Published private(set) var hitCount = 0
    @Published private(set) var pulse = false
    @Published private(set) var audioResult = 0.0
    @Published private(set) var videoResult = 0.0
    @Published private(set) var lastOffset = 0.0

    private let beatInterval = 0.512
    private let requiredHits = 40
    private var startUptime = 0.0
    private var outputLatency = 0.0
    private var lastBeat = -1
    private var offsets: [Double] = []
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func startAudio() {
        stopEngine()
        resetMeasurements()
        stage = .audio

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            outputLatency = (session.outputLatency + session.ioBufferDuration) * 1000

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let buffer = Self.makeClick(format: format)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()

            let firstHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 2.5)
            let beatHost = AVAudioTime.hostTime(forSeconds: beatInterval)
            for i in 0..<120 {
                player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: firstHost + beatHost * UInt64(i)),
                                      options: [], completionHandler: nil)
            }
            player.play(at: AVAudioTime(hostTime: firstHost - AVAudioTime.hostTime(forSeconds: 0.05)))
            self.engine = engine
            self.player = player
            startUptime = AVAudioTime.seconds(forHostTime: firstHost)
        } catch {
            stage = .intro
        }
    }

    func startVideo() {
        stopEngine()
        resetMeasurements()
        stage = .video
        startUptime = ProcessInfo.processInfo.systemUptime + 2.5
        schedulePulse(0)
    }

    func registerTap() {
        guard stage == .audio || stage == .video else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let reference = startUptime + (stage == .audio ? outputLatency / 1000 : 0)
        let relative = now - reference
        let index = Int((relative / beatInterval).rounded())
        guard index >= 0, (stage == .video || index < 120), index != lastBeat else { return }

        let target = reference + Double(index) * beatInterval
        let offset = (now - target) * 1000
        guard abs(offset) <= 220 else { return }

        lastBeat = index
        offsets.append(offset)
        lastOffset = offset
        hitCount += 1

        if hitCount >= requiredHits {
            // 원본은 40회 측정 중 초반 2회를 제외해 평균을 낸다.
            let samples = Array(offsets.dropFirst(2))
            let average = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            let result = min(max((average).rounded(), -200), 500)
            if stage == .audio {
                audioResult = result
                stage = .audioDone
                stopEngine()
            } else {
                videoResult = result
                stage = .videoDone
            }
        }
    }

    func restart() {
        stopEngine()
        stage = .intro
        resetMeasurements()
    }

    func stop() {
        stopEngine()
    }

    private func resetMeasurements() {
        hitCount = 0
        lastBeat = -1
        offsets.removeAll(keepingCapacity: true)
        lastOffset = 0
        pulse = false
    }

    private func stopEngine() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    private func schedulePulse(_ index: Int) {
        guard stage == .video else { return }
        let target = startUptime + Double(index) * beatInterval
        let delay = max(0, target - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.stage == .video else { return }
            self.pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
                self?.pulse = false
            }
            self.schedulePulse(index + 1)
        }
    }

    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let count = AVAudioFrameCount(sampleRate * 0.055)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(count) {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 75)
            samples[i] = Float(sin(2 * Double.pi * 1050 * t) * envelope * 0.7)
        }
        return buffer
    }
}

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("audioOffsetMs") private var audioOffsetMs = 0.0
    @AppStorage("videoOffsetMs") private var videoOffsetMs = 0.0
    @StateObject private var session = CalibrationSession()

    var body: some View {
        VStack(spacing: 22) {
            switch session.stage {
            case .intro:
                Image(systemName: "headphones").font(.system(size: 54))
                Text("싱크 자동 보정").font(.largeTitle.bold())
                Text("실제 플레이할 이어폰이나 헤드폰을 연결한 뒤 진행하세요. 주변 소음이 적은 곳에서 박자마다 한 번씩 화면을 탭하면 됩니다.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("오디오 측정 시작") { session.startAudio() }
                    .buttonStyle(.borderedProminent)
            case .audio:
                activeStage(title: "오디오 싱크 측정", detail: "소리가 들리는 순간마다 탭하세요.")
            case .audioDone:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("오디오 측정 완료").font(.title.bold())
                Text(String(format: "%+.0f ms", session.audioResult)).font(.system(size: 38, weight: .bold, design: .rounded))
                Text("이제 화면에 나타나는 박자에 맞춰 화면 싱크를 측정합니다.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("화면 측정 시작") { session.startVideo() }
                    .buttonStyle(.borderedProminent)
            case .video:
                activeStage(title: "화면 싱크 측정", detail: "화면이 밝아지는 순간마다 탭하세요.")
            case .videoDone:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("측정 완료").font(.title.bold())
                resultRow("오디오 보정", session.audioResult)
                resultRow("화면 보정", session.videoResult)
                Text("현재 보정값을 저장하면 이후 모든 곡에 적용됩니다.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("보정값 저장") {
                    audioOffsetMs = session.audioResult
                    videoOffsetMs = session.videoResult
                    session.stop()
                    dismiss()
                }.buttonStyle(.borderedProminent)
                Button("다시 측정", role: .cancel) { session.restart() }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("싱크 캘리브레이션")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { session.stop() }
    }

    private func activeStage(title: String, detail: String) -> some View {
        VStack(spacing: 22) {
            Text(title).font(.title.bold())
            Text("\(session.hitCount) / 40").font(.system(size: 34, weight: .bold, design: .rounded))
            ProgressView(value: Double(session.hitCount), total: 40)
                .tint(.orange)
            Button(action: { session.registerTap() }) {
                Circle()
                    .fill(session.pulse ? Color.orange : Color(uiColor: .secondarySystemBackground))
                    .overlay(Circle().stroke(Color.orange, lineWidth: 5))
                    .frame(width: 220, height: 220)
                    .overlay(Image(systemName: "hand.tap.fill").font(.system(size: 48)).foregroundStyle(session.pulse ? .white : .orange))
                    .scaleEffect(session.pulse ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.08), value: session.pulse)
            }
            .buttonStyle(.plain)
            Text(detail).foregroundStyle(.secondary)
            Text("마지막 입력 오차  \(String(format: "%+.0f ms", session.lastOffset))")
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func resultRow(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: "%+.0f ms", value)).font(.title3.bold().monospacedDigit())
        }
        .padding(.horizontal, 20)
    }
}
