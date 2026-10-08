import Foundation

/// 用户画像：基本信息（用户填写）+ AI 沉淀的文风画像。
/// 落盘为 diaries/profile.md —— 人读友好、可手改、与其他日记工具互通。
struct UserProfile: Equatable {
    /// 称呼
    var bioName: String = ""
    /// 简介（城市/职业/兴趣等，自由文本）
    var bioAbout: String = ""
    /// AI 沉淀的画像正文（性格与心理 / 喜好 / 日记风格 / 写作视角提示）
    var personaText: String = ""
    /// 画像最近提炼时间
    var updatedAt: Date?
    /// 画像基于的信号条数
    var signalCount: Int = 0
}

/// 画像的采集、持久化与提炼。
/// 信号来源：编辑日记的「原文 → 改后」对照（diaries/profile-edits.md，append-only）、
/// 新增日记计数、高频标签/地点统计、用户填写的基本信息。
@MainActor
final class UserProfileStore: ObservableObject {
    @Published private(set) var profile = UserProfile()
    /// 距上次提炼新增的信号条数（达到阈值自动提炼）
    @Published private(set) var pendingSignals = 0

    /// 自动提炼的信号阈值
    static let autoDistillThreshold = 10
    private static let pendingKey = "profile.pendingSignals"

    private let rootDirectory: URL
    private let defaults: UserDefaults

    init(rootDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("diaries", isDirectory: true)
        self.defaults = defaults
        self.pendingSignals = defaults.integer(forKey: Self.pendingKey)
        self.profile = Self.loadProfile(from: profileURL)
    }

    var profileURL: URL { rootDirectory.appendingPathComponent("profile.md") }
    var editsURL: URL { rootDirectory.appendingPathComponent("profile-edits.md") }

    // MARK: - 画像读写

    func saveProfile() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? Self.renderProfile(profile).write(to: profileURL, atomically: true, encoding: .utf8)
    }

    func updateBio(name: String, about: String) {
        profile.bioName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.bioAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        saveProfile()
    }

    func updatePersona(_ text: String, updatedAt: Date? = nil, signalCount: Int? = nil) {
        profile.personaText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let updatedAt { profile.updatedAt = updatedAt }
        if let signalCount { profile.signalCount = signalCount }
        saveProfile()
    }

    // MARK: - 信号采集

    /// 记录一次「原文 → 修改后」对照（用户编辑日记时调用，最有价值的文风信号）
    func recordEdit(original: String, modified: String, at date: Date = Date()) {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = modified.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, o != m else { return }
        appendToEdits(Self.renderEditBlock(original: o, modified: m, date: date))
        bumpPending()
    }

    /// 新增一条日记（手写或 AI 生成均可，作为生活轨迹信号计数）
    func noteNewEntry() {
        bumpPending()
    }

    private func bumpPending() {
        pendingSignals += 1
        defaults.set(pendingSignals, forKey: Self.pendingKey)
    }

    var needsAutoDistill: Bool { pendingSignals >= Self.autoDistillThreshold }

    private func appendToEdits(_ block: String) {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: editsURL.path) {
            let header = "# 日记修改记录（原文 → 改后，用于提炼用户画像）\n"
            try? header.write(to: editsURL, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: editsURL) {
            handle.seekToEndOfFile()
            handle.write(Data(block.utf8))
            try? handle.close()
        }
    }

    /// 最近的对照修改记录（提炼材料，超长时保留尾部）
    func recentEdits(maxCharacters: Int = 4000) -> String {
        guard let text = try? String(contentsOf: editsURL, encoding: .utf8) else { return "" }
        return text.count > maxCharacters ? String(text.suffix(maxCharacters)) : text
    }

    // MARK: - 提炼

    /// 达到阈值且有 Key 时后台自动提炼（失败静默，信号计数保留，下次再试）
    static func maybeAutoDistill(profileStore: UserProfileStore, config: LLMConfigStore, days: [DiaryDay]) {
        guard profileStore.needsAutoDistill, config.hasAPIKey else { return }
        Task { try? await distill(profileStore: profileStore, config: config, days: days) }
    }

    /// 执行一次画像提炼（手动按钮与自动共用）
    static func distill(profileStore: UserProfileStore, config: LLMConfigStore, days: [DiaryDay]) async throws {
        let totalSignals = profileStore.profile.signalCount + profileStore.pendingSignals
        let prompt = buildDistillPrompt(
            profile: profileStore.profile,
            edits: profileStore.recentEdits(),
            stats: statsSummary(days: days)
        )
        let text = try await LLMService().chat(
            prompt: prompt,
            imageJPEGData: nil,
            config: config.preset,
            apiKey: config.apiKey()
        )
        profileStore.updatePersona(text, updatedAt: Date(), signalCount: totalSignals)
        profileStore.pendingSignals = 0
        profileStore.defaults.set(0, forKey: pendingKey)
    }

    /// 提炼 prompt：旧画像 + 基本信息 + 修改对照 + 统计
    static func buildDistillPrompt(profile: UserProfile, edits: String, stats: String) -> String {
        let oldPersona = profile.personaText.isEmpty ? "（尚无，首次提炼）" : profile.personaText
        let bio = [profile.bioName.isEmpty ? nil : "称呼：\(profile.bioName)",
                   profile.bioAbout.isEmpty ? nil : "简介：\(profile.bioAbout)"]
            .compactMap { $0 }.joined(separator: "\n")
        return """
        你是一位敏锐的文字风格分析师。请根据以下材料，为一位日记作者更新他的个人画像，供 AI 日后以他的视角和口吻代写日记。
        严格按以下四个小标题输出，每段 2~4 句，具体、可执行，不要臆造材料中没有的信息，不要输出其他内容：
        【性格与心理】【喜好】【日记风格】【写作视角提示】

        旧画像（可保留、修正或深化）：
        \(oldPersona)

        作者自填基本信息：
        \(bio.isEmpty ? "（未填写）" : bio)

        最近的日记修改对照（原文 → 作者改后，最能体现其偏好与语感）：
        \(edits.isEmpty ? "（暂无）" : edits)

        生活轨迹统计：
        \(stats)
        """
    }

    /// 生活轨迹统计：高频标签、常去地点、日记总量
    static func statsSummary(days: [DiaryDay], top: Int = 8) -> String {
        var tagCounts: [String: Int] = [:]
        var locationCounts: [String: Int] = [:]
        var entryCount = 0
        for day in days {
            for entry in day.entries where !entry.isDaySummary {
                entryCount += 1
                for tag in entry.tags { tagCounts[tag, default: 0] += 1 }
                if let location = entry.locationName, !location.isEmpty {
                    locationCounts[location, default: 0] += 1
                }
            }
        }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(top)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "、")
        let topLocations = locationCounts.sorted { $0.value > $1.value }.prefix(top)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "、")
        return """
        累计 \(days.count) 天、\(entryCount) 条日记
        高频标签：\(topTags.isEmpty ? "（暂无）" : topTags)
        常去地点：\(topLocations.isEmpty ? "（暂无）" : topLocations)
        """
    }

    // MARK: - profile.md 渲染/解析（纯函数）

    static func renderProfile(_ p: UserProfile) -> String {
        var lines = [
            "# 用户画像",
            "",
            "## 基本信息（我填写的）",
            "",
            "- 称呼：\(p.bioName)",
            "- 简介：\(p.bioAbout)",
            "",
            "## AI 画像（根据我的日记自动沉淀，可手改）",
            "",
        ]
        if let updatedAt = p.updatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            lines.append("<!-- updated: \(formatter.string(from: updatedAt)) · signals: \(p.signalCount) -->")
            lines.append("")
        }
        lines.append(p.personaText)
        return lines.joined(separator: "\n") + "\n"
    }

    static func loadProfile(from url: URL) -> UserProfile {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return UserProfile() }
        var profile = UserProfile()
        var personaLines: [String] = []
        var inPersona = false
        let updatedFormatter = DateFormatter()
        updatedFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        updatedFormatter.locale = Locale(identifier: "en_US_POSIX")

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inPersona = line.contains("AI 画像")
                continue
            }
            if line.hasPrefix("- 称呼：") {
                profile.bioName = String(line.dropFirst(5))
                continue
            }
            if line.hasPrefix("- 简介：") {
                profile.bioAbout = String(line.dropFirst(5))
                continue
            }
            if inPersona, line.hasPrefix("<!-- updated: ") {
                // <!-- updated: 2026-10-08T17:00:00+08:00 · signals: 12 -->
                let inner = line.dropFirst(14).components(separatedBy: " · signals: ")
                if let first = inner.first {
                    profile.updatedAt = updatedFormatter.date(from: first)
                }
                if inner.count > 1, let count = Int(inner[1].replacingOccurrences(of: " -->", with: "")) {
                    profile.signalCount = count
                }
                continue
            }
            if inPersona {
                personaLines.append(rawLine)
            }
        }
        profile.personaText = personaLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return profile
    }

    // MARK: - 修改对照记录块

    static func renderEditBlock(original: String, modified: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        func quote(_ text: String) -> String {
            text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
        }
        return """

        ## \(formatter.string(from: date))

        原文：
        \(quote(original))

        改后：
        \(quote(modified))

        ---

        """
    }
}
