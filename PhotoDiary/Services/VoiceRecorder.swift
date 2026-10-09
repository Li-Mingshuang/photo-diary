import Foundation
import Speech
import AVFoundation

/// 语音录制 + 实时转录（系统 Speech 框架，优先端侧识别，转录不出本机、免费、无需 API Key）。
/// 音频同时写入临时 m4a，保存日记时由 DiaryStore 拷入 diaries/audio/（用户可选择不保留）。
@MainActor
final class VoiceRecorder: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        /// 权限被拒绝（引导去系统设置）
        case denied
        /// 设备/识别不可用（如模拟器无语音服务）
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var duration: TimeInterval = 0

    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?

    static let locale = Locale(identifier: "zh-CN")

    // MARK: - 权限

    /// 请求麦克风 + 语音识别权限，返回是否均被允许
    static func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - 录制

    /// 开始录音与实时转录；失败时设置 state 并抛出错误
    func start() async throws {
        guard state != .recording else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale) else {
            state = .unavailable("当前环境不支持语音识别（模拟器上可能不可用，请在真机使用）")
            return
        }
        guard recognizer.isAvailable else {
            state = .unavailable("语音识别暂时不可用，请稍后再试")
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        // 优先端侧识别：设备支持则强制不出网；不支持则由系统决定（设置页已声明隐私口径）
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true

        // 临时音频文件（保存日记时才归档，取消则删除）
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicerec-\(UUID().uuidString).m4a")
        let audioFile = try? AVAudioFile(forWriting: tempURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])

        transcript = ""
        duration = 0
        let recordingStart = Date()
        startedAt = recordingStart

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.transcript = text }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.finishCapture() }
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            try? audioFile?.write(from: buffer)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.recognitionRequest = request
        self.audioFile = audioFile
        self.tempFileURL = audioFile != nil ? tempURL : nil
        state = .recording

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.duration = Date().timeIntervalSince(recordingStart)
            }
        }
    }

    /// 结束录制，返回（临时音频文件, 最终转录）；音频可能为 nil（写入失败降级）
    @discardableResult
    func stop() -> (audioURL: URL?, transcript: String, startedAt: Date?) {
        finishCapture()
        state = .idle
        return (tempFileURL, transcript, startedAt)
    }

    /// 取消录制：清理并删除临时音频
    func cancel() {
        finishCapture()
        if let tempFileURL { try? FileManager.default.removeItem(at: tempFileURL) }
        tempFileURL = nil
        transcript = ""
        duration = 0
        state = .idle
    }

    private func finishCapture() {
        timerTask?.cancel()
        timerTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        audioFile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 详情页音频播放（同时只播一条）
@MainActor
final class AudioPlayerService: ObservableObject {
    /// 正在播放的音频文件名（用于按钮状态）
    @Published private(set) var playingFileName: String?

    private var player: AVAudioPlayer?

    func toggle(fileName: String, url: URL) {
        if playingFileName == fileName {
            stop()
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            playingFileName = fileName
        } catch {
            playingFileName = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingFileName = nil
    }
}
