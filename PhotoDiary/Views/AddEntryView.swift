import SwiftUI

/// 新增日记：预览照片与元数据 → AI 生成 → 可编辑 → 保存
struct AddEntryView: View {
    let draft: EntryDraft
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var didAutoGenerate = false

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

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("日记正文")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task { await generate() }
                            } label: {
                                Label("重新生成", systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                            }
                            .disabled(isGenerating)
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
                await generate()
            }
        }
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
                locationName: draft.locationName
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
                text = accumulated
            }
            text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        let entry = DiaryEntry(
            createdAt: draft.takenAt,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            locationName: draft.locationName,
            latitude: draft.location?.coordinate.latitude,
            longitude: draft.location?.coordinate.longitude
        )
        do {
            try store.addEntry(entry, image: draft.image)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
