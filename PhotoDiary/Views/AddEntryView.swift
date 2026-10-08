import SwiftUI

/// 新增日记：预览照片与元数据 → AI 生成 → 可编辑 → 保存
struct AddEntryView: View {
    let draft: EntryDraft
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var title = ""
    @State private var tags: [String] = []
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var didAutoGenerate = false
    @State private var generateTask: Task<Void, Never>?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(uiImage: draft.image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    metadataSection

                    if isGenerating {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("AI 正在写日记…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    }

                    // AI 生成的标题（可编辑）与标签
                    if !title.isEmpty || !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if !title.isEmpty {
                                TextField("标题", text: $title)
                                    .font(.headline)
                                    .padding(10)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .disabled(isGenerating)
                            }
                            if !tags.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(tags, id: \.self) { tag in
                                        TagCapsule(tag: tag)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("日记正文")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isGenerating {
                                Button(role: .cancel) {
                                    generateTask?.cancel()
                                } label: {
                                    Label("停止", systemImage: "stop.circle")
                                        .font(.subheadline)
                                }
                            } else {
                                Button {
                                    startGeneration()
                                } label: {
                                    Label("重新生成", systemImage: "arrow.clockwise")
                                        .font(.subheadline)
                                }
                            }
                        }

                        TextEditor(text: $text)
                            .accessibilityIdentifier("diaryTextEditor")
                            .frame(minHeight: 140)
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .disabled(isGenerating)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        // 缺 Key 时给出直达设置的入口
                        if !config.hasAPIKey {
                            Button("去设置 API Key") {
                                showingSettings = true
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("新日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                }
            }
            .task {
                guard !didAutoGenerate else { return }
                didAutoGenerate = true
                startGeneration()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(config: config, profileStore: profileStore, diaryStore: store)
            }
        }
    }

    private func startGeneration() {
        generateTask?.cancel()
        generateTask = Task { await generate() }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(draft.takenAt.formatted(date: .long, time: .shortened), systemImage: "clock")
            Label(draft.locationName ?? "位置未知", systemImage: "mappin.and.ellipse")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func generate() async {
        guard config.hasAPIKey else {
            errorMessage = "还没有配置 API Key，可以在右上角设置里填写后再点「重新生成」。"
            return
        }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let prompt = PromptBuilder.buildPrompt(
                template: config.promptTemplate,
                date: draft.takenAt,
                locationName: draft.locationName,
                persona: profileStore.profile.personaText
            )
            let imageData = draft.image.downscaledTo(maxDimension: 1280).jpegData(compressionQuality: 0.7)
            // 流式生成：逐段填充，用户可以看着日记写出来
            var accumulated = ""
            for try await delta in LLMService().chatStream(
                prompt: prompt,
                imageJPEGData: imageData,
                config: config.preset,
                apiKey: config.apiKey()
            ) {
                accumulated += delta
                // 流式阶段：从部分 JSON 里提取已生成的正文用于展示
                text = DiaryGenerationParser.displayText(forPartial: accumulated)
            }
            let parsed = DiaryGenerationParser.parse(accumulated)
            text = parsed.text
            title = parsed.title ?? ""
            tags = parsed.tags
        } catch {
            if Task.isCancelled { return } // 用户主动停止，保留已生成部分
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = DiaryEntry(
            createdAt: draft.takenAt,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            locationName: draft.locationName,
            latitude: draft.location?.coordinate.latitude,
            longitude: draft.location?.coordinate.longitude,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            tags: tags
        )
        do {
            try store.addEntry(entry, image: draft.image)
            // 新日记是一条画像信号；满阈值后台自动提炼
            profileStore.noteNewEntry()
            UserProfileStore.maybeAutoDistill(profileStore: profileStore, config: config, days: store.days)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 标签胶囊（#tag 样式）
struct TagCapsule: View {
    let tag: String

    var body: some View {
        Text("#\(tag)")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}
