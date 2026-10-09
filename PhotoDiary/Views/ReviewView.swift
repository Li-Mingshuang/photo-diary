import SwiftUI
import MapKit

/// 回顾 Tab：统计洞察 / 标签墙 / 地图足迹 / 月度回顾（L3 生活档案）
struct ReviewView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore

    @State private var selectedTag: String?
    @State private var selectedDayKey: String?
    @State private var mapSelection: String?
    @State private var monthlySheet: MonthlyContext?
    /// 月记 sheet 关闭后触发列表刷新（月记文件不走按天索引，需要手动刷新状态）
    @State private var refreshToken = 0

    private struct MonthlyContext: Identifiable {
        let monthKey: String
        var id: String { monthKey }
    }

    var body: some View {
        Group {
            if store.days.isEmpty {
                ContentUnavailableView {
                    Label("还没有可回顾的内容", systemImage: "calendar")
                } description: {
                    Text("先去「日记」页拍几张照片，\n这里会长出你的标签墙、足迹地图和月记。")
                        .multilineTextAlignment(.center)
                }
            } else {
                List {
                    insightSection
                    tagCloudSection
                    mapSection
                    monthlySection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("回顾")
        .navigationDestination(item: $selectedTag) { tag in
            TagEntriesView(tag: tag, store: store, config: config, profileStore: profileStore)
        }
        .navigationDestination(item: $selectedDayKey) { dayKey in
            DayDetailView(dayKey: dayKey, store: store, config: config, profileStore: profileStore)
        }
        .sheet(item: $monthlySheet, onDismiss: { refreshToken += 1 }) { context in
            MonthlySummaryView(monthKey: context.monthKey, store: store, config: config, profileStore: profileStore)
        }
    }

    // MARK: - 统计洞察卡

    @ViewBuilder
    private var insightSection: some View {
        let insight = DiaryStats.insight(days: store.days)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(insight.dayCount) 天 · \(insight.entryCount) 条记录")
                    .font(.headline)
                HStack(spacing: 12) {
                    if let location = insight.topLocation {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                    if !insight.topTags.isEmpty {
                        Label(insight.topTags.map { "#\($0)" }.joined(separator: " "), systemImage: "tag")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("一览")
        } footer: {
            if let location = insight.topLocation {
                Text("最常去：\(location) · 高频标签：\(insight.topTags.joined(separator: "、"))")
            }
        }
    }

    // MARK: - 标签墙

    @ViewBuilder
    private var tagCloudSection: some View {
        let cloud = DiaryStats.tagCloud(days: store.days)
        if !cloud.isEmpty {
            Section("标签墙") {
                let maxCount = cloud.first?.count ?? 1
                FlowLayout(spacing: 8) {
                    ForEach(cloud, id: \.tag) { item in
                        Button {
                            selectedTag = item.tag
                        } label: {
                            Text("#\(item.tag)")
                                .font(fontSize(for: item.count, max: maxCount))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(opacity(for: item.count, max: maxCount)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 热度 → 字号（caption ~ title3）
    private func fontSize(for count: Int, max maxCount: Int) -> Font {
        switch Double(count) / Double(max(maxCount, 1)) {
        case 0.75...: return .title3.weight(.semibold)
        case 0.5...: return .headline
        case 0.25...: return .subheadline
        default: return .caption
        }
    }

    private func opacity(for count: Int, max maxCount: Int) -> Double {
        0.08 + 0.14 * (Double(count) / Double(max(maxCount, 1)))
    }

    // MARK: - 地图足迹

    @ViewBuilder
    private var mapSection: some View {
        let located = DiaryStats.locatedEntries(days: store.days)
        if !located.isEmpty {
            Section("足迹地图") {
                Map(selection: $mapSelection) {
                    ForEach(located, id: \.entry.id) { item in
                        Marker(item.dayKey, coordinate: CLLocationCoordinate2D(
                            latitude: item.entry.latitude!, longitude: item.entry.longitude!
                        ))
                        .tint(.orange)
                        .tag(item.dayKey)
                    }
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .onChange(of: mapSelection) { _, selection in
                    guard let selection else { return }
                    selectedDayKey = selection
                    mapSelection = nil
                }
                Text("\(located.count) 个足迹点 · 共 \(Set(located.map(\.dayKey)).count) 天 · 点标注看当天日记")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 月度回顾

    @ViewBuilder
    private var monthlySection: some View {
        let groups = DiaryStats.monthlyGroups(days: store.days)
        if !groups.isEmpty {
            Section("月度回顾") {
                // refreshToken 仅用于触发月记状态刷新
                let _ = refreshToken
                ForEach(groups, id: \.month) { group in
                    Button {
                        monthlySheet = MonthlyContext(monthKey: group.month)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MonthlySummaryCodec.monthTitle(for: group.month))
                                    .font(.headline)
                                Text("\(group.dayCount) 天 · \(group.entryCount) 条记录")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let summary = store.loadMonthlySummary(for: group.month) {
                                Label("已生成", systemImage: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                                if let date = summary.generatedAt {
                                    Text(date.formatted(date: .numeric, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Label("生成月记", systemImage: "sparkles")
                                    .font(.footnote)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }
}

/// 点标签后的筛选结果页
private struct TagEntriesView: View {
    let tag: String
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore

    private var matchedDays: [DiaryDay] {
        DiarySearch.filter(store.days, query: "#\(tag)")
    }

    var body: some View {
        List(matchedDays) { day in
            NavigationLink {
                DayDetailView(dayKey: day.key, store: store, config: config, profileStore: profileStore)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.title).font(.headline)
                    Text("\(day.entries.count) 条命中 · \(day.summary)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .navigationTitle("#\(tag)")
    }
}

/// 月记查看/生成（流式，完成后落盘 diaries/monthly/yyyy-MM.md）
private struct MonthlySummaryView: View {
    let monthKey: String
    @ObservedObject var store: DiaryStore
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var existing: MonthlySummaryCodec.MonthlySummary?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generateTask: Task<Void, Never>?

    private var monthDays: [DiaryDay] {
        store.days.filter { $0.key.hasPrefix(monthKey) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isGenerating {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("AI 正在写月记…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                    } else if let existing {
                        Text(existing.text)
                            .textSelection(.enabled)
                        if let date = existing.generatedAt {
                            Text("生成于 \(date.formatted(date: .long, time: .shortened)) · \(existing.model ?? "") · 基于 \(existing.entryCount) 条记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        ContentUnavailableView {
                            Label("还没有月记", systemImage: "sparkles")
                        } description: {
                            Text("基于本月 \(monthDays.count) 天的日记片段，AI 会写一篇连贯的月度回顾。")
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("\(MonthlySummaryCodec.monthTitle(for: monthKey)) · 月记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        generateTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        Button(role: .cancel) { generateTask?.cancel() } label: {
                            Label("停止", systemImage: "stop.circle")
                        }
                    } else {
                        Button(existing == nil && text.isEmpty ? "生成" : "重新生成") { startGeneration() }
                            .disabled(!config.hasAPIKey || monthDays.isEmpty)
                    }
                }
            }
            .onAppear { existing = store.loadMonthlySummary(for: monthKey) }
        }
    }

    private func startGeneration() {
        generateTask?.cancel()
        generateTask = Task { await generate() }
    }

    private func generate() async {
        guard config.hasAPIKey else {
            errorMessage = "还没有配置 API Key，去「日记」页左上角设置里填写。"
            return
        }
        isGenerating = true
        errorMessage = nil
        text = ""
        defer { isGenerating = false }
        do {
            let prompt = PromptBuilder.buildMonthlySummaryPrompt(
                template: DefaultPrompt.monthlySummaryTemplate,
                month: MonthlySummaryCodec.monthTitle(for: monthKey),
                days: monthDays,
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
            if Task.isCancelled { return }
            let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            let entryCount = monthDays.reduce(0) { $0 + $1.entries.filter { !$0.isDaySummary }.count }
            try store.saveMonthlySummary(
                monthKey: monthKey, text: finalText, model: config.preset.model, entryCount: entryCount
            )
            existing = store.loadMonthlySummary(for: monthKey)
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// 简单的流式布局（标签墙用）：按内容宽度换行
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
