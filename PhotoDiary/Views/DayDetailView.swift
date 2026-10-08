import SwiftUI

/// 某一天的日记详情：条目卡片流 + 导出 Markdown
struct DayDetailView: View {
    let dayKey: String
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore

    @State private var editingEntry: DiaryEntry?
    @State private var regeneratingEntryID: UUID?
    @State private var regenerateTask: Task<Void, Never>?
    @State private var isSummarizing = false
    @State private var summaryTask: Task<Void, Never>?
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
                                onRegenerate: { startRegenerate(entry) },
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
                HStack(spacing: 16) {
                    // 当日小结：把一天的照片合并生成一篇
                    if isSummarizing {
                        Button {
                            summaryTask?.cancel()
                        } label: {
                            ProgressView()
                        }
                    } else {
                        Button {
                            startSummary()
                        } label: {
                            Image(systemName: "text.quote")
                        }
                        .accessibilityIdentifier("daySummaryButton")
                    }
                    ShareLink(item: store.markdownURL(forDayKey: dayKey)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            EditEntryView(entry: entry) { updated in
                // 记录「原文 → 改后」对照，作为画像提炼最有价值的信号
                profileStore.recordEdit(original: entry.text, modified: updated.text)
                store.updateEntry(updated)
                UserProfileStore.maybeAutoDistill(profileStore: profileStore, config: config, days: store.days)
            }
        }
        .alert("操作失败", isPresented: .constant(actionError != nil)) {
            Button("好的") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func startRegenerate(_ entry: DiaryEntry) {
        regenerateTask?.cancel()
        regenerateTask = Task { await regenerate(entry) }
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
                locationName: entry.locationName,
                persona: profileStore.profile.personaText
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
                updated.text = DiaryGenerationParser.displayText(forPartial: accumulated)
                store.updateEntry(updated) // 边生成边刷新界面
            }
            let parsed = DiaryGenerationParser.parse(accumulated)
            updated.text = parsed.text
            updated.title = parsed.title
            updated.tags = parsed.tags
            store.updateEntry(updated)
        } catch {
            if Task.isCancelled { return } // 用户主动停止，保留已生成部分
            actionError = error.localizedDescription
        }
    }

    // MARK: - 当日小结

    private func startSummary() {
        guard config.hasAPIKey else {
            actionError = "还没有配置 API Key，请先在设置中填写。"
            return
        }
        summaryTask?.cancel()
        summaryTask = Task { await generateDaySummary() }
    }

    private func generateDaySummary() async {
        let photoEntries = (day?.entries ?? []).filter { $0.imageFileName != nil && !$0.isDaySummary }
        guard !photoEntries.isEmpty else {
            actionError = "今天还没有带照片的记录，无法生成小结。"
            return
        }
        isSummarizing = true
        defer { isSummarizing = false }
        // 多图合并时单图降得更小，控制请求体总量
        let images = photoEntries.compactMap { entry -> Data? in
            guard let fileName = entry.imageFileName,
                  let image = Thumbnailer.image(at: store.imageURL(for: fileName), maxPixelSize: 1024) else { return nil }
            return image.jpegData(compressionQuality: 0.6)
        }
        let prompt = PromptBuilder.buildDaySummaryPrompt(
            template: DefaultPrompt.daySummaryTemplate,
            entries: photoEntries,
            persona: profileStore.profile.personaText
        )
        var accumulated = ""
        do {
            for try await delta in LLMService().chatStreamMulti(
                prompt: prompt,
                imagesJPEGData: images,
                config: config.preset,
                apiKey: config.apiKey()
            ) {
                accumulated += delta
                upsertSummary(accumulated)
            }
            upsertSummary(accumulated.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            if Task.isCancelled { return }
            actionError = error.localizedDescription
        }
    }

    /// 已有小结则更新，没有则新建（createdAt 取当天 23:59，排序在最后）
    private func upsertSummary(_ text: String) {
        if let existing = day?.entries.first(where: { $0.isDaySummary }) {
            var updated = existing
            updated.text = text
            store.updateEntry(updated)
        } else {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: DayKey.date(for: dayKey) ?? Date())
            components.hour = 23
            components.minute = 59
            let createdAt = Calendar.current.date(from: components) ?? Date()
            let entry = DiaryEntry(createdAt: createdAt, text: text, isDaySummary: true)
            try? store.addEntry(entry, image: nil)
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
                if entry.isDaySummary {
                    Label("当日小结", systemImage: "sparkles")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                } else {
                    Text(entry.timeString)
                        .font(.subheadline.bold())
                }
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
                    if !entry.isDaySummary {
                        Button(action: onRegenerate) {
                            Label("重新生成", systemImage: "arrow.clockwise")
                        }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("entryMenuButton")
            }

            // AI 生成的标题
            if let title = entry.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
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

            // AI 生成的标签
            if !entry.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.tags, id: \.self) { tag in
                        TagCapsule(tag: tag)
                    }
                }
            }
        }
        .padding()
        .background(entry.isDaySummary ? Color.orange.opacity(0.08) : Color(.secondarySystemBackground))
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
