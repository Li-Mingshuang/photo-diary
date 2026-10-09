import SwiftUI

/// 语音日记：录音 → 系统实时转录（优先端侧）→ AI 整理或仅转录 → 保存
struct VoiceEntryView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var recorder = VoiceRecorder()

    private enum PolishMode: String, CaseIterable {
        case ai = "AI 整理"
        case raw = "仅转录"
    }

    @State private var permissionDenied = false
    @State private var hasRecorded = false
    @State private var recordedAt: Date?
    @State private var tempAudioURL: URL?
    @State private var keepAudio = true
    @State private var mode: PolishMode = .ai
    @State private var text = ""
    @State private var rawTranscript = ""
    @State private var isPolishing = false
    @State private var errorMessage: String?
    @State private var polishTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    recordSection
                    if hasRecorded {
                        optionsSection
                        textSection
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("语音日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        polishTask?.cancel()
                        recorder.cancel()
                        cleanupTempAudioIfNeeded()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .task { await preparePermissions() }
        }
    }

    private var canSave: Bool {
        hasRecorded && recorder.state != .recording && !isPolishing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 录音区

    @ViewBuilder
    private var recordSection: some View {
        if permissionDenied {
            ContentUnavailableView {
                Label("需要麦克风与语音识别权限", systemImage: "mic.slash")
            } description: {
                Text("去系统设置开启后才能录制语音日记。")
            } actions: {
                Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .buttonStyle(.borderedProminent)
            }
        } else if case .unavailable(let reason) = recorder.state {
            Label(reason, systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            VStack(spacing: 12) {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Image(systemName: recorder.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(recorder.state == .recording ? .red : Color.accentColor)
                        .symbolEffect(.pulse, isActive: recorder.state == .recording)
                }
                .accessibilityIdentifier("recordButton")

                Text(recorder.state == .recording
                     ? "录音中 \(formatDuration(recorder.duration))，点按停止"
                     : (hasRecorded ? "点按重新录制" : "点按开始说话"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // 录音中实时转录
                if recorder.state == .recording, !recorder.transcript.isEmpty {
                    Text(recorder.transcript)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - 选项区（录音完成后）

    private var optionsSection: some View {
        VStack(spacing: 12) {
            Toggle("保留原声（存入 diaries/audio/）", isOn: $keepAudio)
                .font(.subheadline)

            Picker("成文方式", selection: $mode) {
                ForEach(PolishMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isPolishing)
            .onChange(of: mode) { _, newMode in
                if newMode == .raw {
                    polishTask?.cancel()
                    isPolishing = false
                    text = rawTranscript
                } else {
                    startPolish()
                }
            }

            if mode == .ai, !config.hasAPIKey {
                Text("未配置 API Key，已降级为仅转录。去「日记」页左上角设置里填写后可 AI 整理。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 正文区

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mode == .ai ? "整理后正文（可编辑）" : "转录原文（可编辑）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isPolishing {
                    Button(role: .cancel) { polishTask?.cancel() } label: {
                        Label("停止", systemImage: "stop.circle").font(.subheadline)
                    }
                } else if mode == .ai, config.hasAPIKey {
                    Button { startPolish() } label: {
                        Label("重新整理", systemImage: "arrow.clockwise").font(.subheadline)
                    }
                }
            }
            TextEditor(text: $text)
                .accessibilityIdentifier("voiceTextEditor")
                .frame(minHeight: 140)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(isPolishing)
        }
    }

    // MARK: - 流程

    private func preparePermissions() async {
        let granted = await VoiceRecorder.requestPermissions()
        permissionDenied = !granted
    }

    private func toggleRecording() async {
        if recorder.state == .recording {
            let result = recorder.stop()
            recordedAt = result.startedAt ?? Date()
            tempAudioURL = result.audioURL
            rawTranscript = result.transcript
            text = result.transcript
            hasRecorded = true
            errorMessage = nil
            if mode == .ai { startPolish() }
            return
        }
        // 重新录制：丢弃上一份临时音频
        cleanupTempAudioIfNeeded()
        hasRecorded = false
        do {
            try await recorder.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPolish() {
        guard config.hasAPIKey else {
            mode = .raw
            text = rawTranscript
            return
        }
        polishTask?.cancel()
        polishTask = Task { await polish() }
    }

    private func polish() async {
        isPolishing = true
        errorMessage = nil
        text = ""
        defer { isPolishing = false }
        do {
            let prompt = PromptBuilder.buildVoicePolishPrompt(
                template: DefaultPrompt.voicePolishTemplate,
                date: recordedAt ?? Date(),
                transcript: rawTranscript,
                persona: profileStore.profile.personaText
            )
            var accumulated = ""
            for try await delta in LLMService().chatStreamMulti(
                prompt: prompt,
                imagesJPEGData: [],
                config: config.preset,
                apiKey: config.apiKey()
            ) {
                accumulated += delta
                text = accumulated
            }
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            text = rawTranscript // 失败兜底：回到转录原文
        }
    }

    private func save() {
        let entry = DiaryEntry(
            createdAt: recordedAt ?? Date(),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try store.addEntry(entry, image: nil, audio: keepAudio ? tempAudioURL : nil)
            cleanupTempAudioIfNeeded(force: true)
            profileStore.noteNewEntry()
            UserProfileStore.maybeAutoDistill(profileStore: profileStore, config: config, days: store.days)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 不保留原声（或保存成功后）删除临时音频；force 用于保存后兜底清理
    private func cleanupTempAudioIfNeeded(force: Bool = false) {
        guard let url = tempAudioURL else { return }
        if force || !keepAudio {
            try? FileManager.default.removeItem(at: url)
        }
        tempAudioURL = nil
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
