import SwiftUI

/// 某一天的日记详情：条目卡片流 + 导出 Markdown
struct DayDetailView: View {
    let dayKey: String
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore

    @State private var editingEntry: DiaryEntry?
    @State private var regeneratingEntryID: UUID?
    @State private var actionError: String?

    private var day: DiaryDay? {
        store.days.first { $0.key == dayKey }
    }

    var body: some View {
        Group {
            if let day {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(day.entries) { entry in
                            EntryCardView(
                                entry: entry,
                                imageURL: entry.imageFileName.map { store.imageURL(for: $0) },
                                isRegenerating: regeneratingEntryID == entry.id,
                                onEdit: { editingEntry = entry },
                                onRegenerate: { Task { await regenerate(entry) } },
                                onDelete: { store.deleteEntry(entry) }
                            )
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("这一天还没有记录", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .navigationTitle(day?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: store.markdownURL(forDayKey: dayKey)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditEntryView(entry: entry) { updated in
                store.updateEntry(updated)
            }
        }
        .alert("操作失败", isPresented: .constant(actionError != nil)) {
            Button("好的") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func regenerate(_ entry: DiaryEntry) async {
        guard config.hasAPIKey else {
            actionError = "还没有配置 API Key，请先在设置中填写。"
            return
        }
        regeneratingEntryID = entry.id
        defer { regeneratingEntryID = nil }
        do {
            var imageData: Data?
            if let fileName = entry.imageFileName,
               let image = UIImage(contentsOfFile: store.imageURL(for: fileName).path) {
                imageData = image.downscaledTo(maxDimension: 1280).jpegData(compressionQuality: 0.7)
            }
            let prompt = PromptBuilder.buildPrompt(
                template: config.promptTemplate,
                date: entry.createdAt,
                locationName: entry.locationName
            )
            var updated = entry
            var accumulated = ""
            for try await delta in LLMService().chatStream(
                prompt: prompt,
                imageJPEGData: imageData,
                config: config.preset,
                apiKey: config.apiKey()
            ) {
                accumulated += delta
                updated.text = accumulated
                store.updateEntry(updated) // 边生成边刷新界面
            }
            updated.text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateEntry(updated)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// 单条日记卡片
private struct EntryCardView: View {
    let entry: DiaryEntry
    let imageURL: URL?
    let isRegenerating: Bool
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(entry.timeString)
                    .font(.subheadline.bold())
                if let location = entry.locationName {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button(action: onEdit) {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(action: onRegenerate) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }

            // ImageIO 降采样加载，避免全尺寸图片占内存
            if let imageURL, let image = Thumbnailer.image(at: imageURL, maxPixelSize: 1400) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if isRegenerating && entry.text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("AI 正在重新生成…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                // AI 产出可能含 Markdown 标记，按行内语法渲染
                Text(Self.markdown(entry.text))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 编辑单条日记
private struct EditEntryView: View {
    let entry: DiaryEntry
    let onSave: (DiaryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(entry: DiaryEntry, onSave: @escaping (DiaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(8)
                .navigationTitle("编辑日记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            var updated = entry
                            updated.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(updated)
                            dismiss()
                        }
                    }
                }
        }
    }
}
