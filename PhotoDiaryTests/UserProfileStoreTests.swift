import XCTest
@testable import PhotoDiary

@MainActor
final class UserProfileStoreTests: XCTestCase {

    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var store: UserProfileStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "profile-test-\(UUID().uuidString)")
        store = UserProfileStore(rootDirectory: tempDir, defaults: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - profile.md 渲染/解析

    func testProfileRenderAndLoadRoundTrip() {
        var profile = UserProfile()
        profile.bioName = "阿明"
        profile.bioAbout = "上海 · 程序员 · 喜欢扫街"
        profile.personaText = "【性格与心理】内向细腻。\n【日记风格】短句为主。"
        profile.updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        profile.signalCount = 12

        let markdown = UserProfileStore.renderProfile(profile)
        XCTAssertTrue(markdown.contains("- 称呼：阿明"))
        XCTAssertTrue(markdown.contains("signals: 12"))

        // 落盘再读回
        let url = tempDir.appendingPathComponent("profile.md")
        try! markdown.write(to: url, atomically: true, encoding: .utf8)
        let loaded = UserProfileStore.loadProfile(from: url)
        XCTAssertEqual(loaded.bioName, profile.bioName)
        XCTAssertEqual(loaded.bioAbout, profile.bioAbout)
        XCTAssertEqual(loaded.personaText, profile.personaText)
        XCTAssertEqual(loaded.signalCount, 12)
        XCTAssertNotNil(loaded.updatedAt)
        XCTAssertEqual(loaded.updatedAt!.timeIntervalSince1970, profile.updatedAt!.timeIntervalSince1970, accuracy: 1)
    }

    func testLoadProfileMissingFileReturnsDefault() {
        let loaded = UserProfileStore.loadProfile(from: tempDir.appendingPathComponent("nope.md"))
        XCTAssertEqual(loaded, UserProfile())
    }

    // MARK: - 信号采集

    func testRecordEditAppendsAndBumps() {
        store.recordEdit(original: "下午路过公园，阳光很好。", modified: "下午溜达到公园，银杏黄了。")
        XCTAssertEqual(store.pendingSignals, 1)
        let edits = store.recentEdits()
        XCTAssertTrue(edits.contains("原文："))
        XCTAssertTrue(edits.contains("> 下午路过公园，阳光很好。"))
        XCTAssertTrue(edits.contains("改后："))
        XCTAssertTrue(edits.contains("> 下午溜达到公园，银杏黄了。"))
    }

    func testRecordEditIgnoresIdenticalOrEmpty() {
        store.recordEdit(original: "一样", modified: "一样")
        store.recordEdit(original: "  ", modified: "有内容")
        XCTAssertEqual(store.pendingSignals, 0)
        XCTAssertEqual(store.recentEdits(), "")
    }

    func testAutoDistillThreshold() {
        XCTAssertFalse(store.needsAutoDistill)
        for _ in 0..<UserProfileStore.autoDistillThreshold {
            store.noteNewEntry()
        }
        XCTAssertTrue(store.needsAutoDistill)
    }

    func testRecentEditsTruncatesToTail() {
        let long = String(repeating: "很长的一段正文。", count: 2000)
        store.recordEdit(original: long, modified: "改")
        let edits = store.recentEdits(maxCharacters: 500)
        XCTAssertLessThanOrEqual(edits.count, 500)
        XCTAssertTrue(edits.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("---"))
    }

    // MARK: - 统计与提炼 Prompt

    private func makeDay(_ key: String, entries: [DiaryEntry]) -> DiaryDay {
        DiaryDay(key: key, entries: entries)
    }

    func testStatsSummary() {
        let days = [
            makeDay("2026-10-07", entries: [
                DiaryEntry(createdAt: Date(), text: "a", locationName: "静安公园", tags: ["公园", "秋天"]),
                DiaryEntry(createdAt: Date(), text: "b", locationName: "静安公园", tags: ["公园"]),
                DiaryEntry(createdAt: Date(), text: "小结", isDaySummary: true, tags: ["不计入"]),
            ]),
            makeDay("2026-10-06", entries: [
                DiaryEntry(createdAt: Date(), text: "c", locationName: "海底捞", tags: ["火锅"]),
            ]),
        ]
        let stats = UserProfileStore.statsSummary(days: days)
        XCTAssertTrue(stats.contains("累计 2 天、3 条日记")) // 小结不计入（3 = 2 + 1）
        XCTAssertTrue(stats.contains("公园×2"))
        XCTAssertTrue(stats.contains("静安公园×2"))
        XCTAssertFalse(stats.contains("不计入"))
    }

    func testBuildDistillPromptContainsAllMaterials() {
        var profile = UserProfile()
        profile.bioName = "阿明"
        profile.personaText = "旧画像内容"
        let prompt = UserProfileStore.buildDistillPrompt(
            profile: profile,
            edits: "修改对照内容",
            stats: "统计内容"
        )
        for section in ["【性格与心理】", "【喜好】", "【日记风格】", "【写作视角提示】"] {
            XCTAssertTrue(prompt.contains(section), "缺少 \(section)")
        }
        XCTAssertTrue(prompt.contains("旧画像内容"))
        XCTAssertTrue(prompt.contains("称呼：阿明"))
        XCTAssertTrue(prompt.contains("修改对照内容"))
        XCTAssertTrue(prompt.contains("统计内容"))
    }

    // MARK: - PromptBuilder 画像注入

    func testPromptBuilderAppendsPersona() {
        let prompt = PromptBuilder.buildPrompt(
            template: "写日记 {location}",
            date: Date(),
            locationName: "公园",
            persona: "【日记风格】短句、克制。"
        )
        XCTAssertTrue(prompt.contains("写日记 公园"))
        XCTAssertTrue(prompt.contains("作者背景与文风"))
        XCTAssertTrue(prompt.contains("【日记风格】短句、克制。"))
    }

    func testPromptBuilderSkipsEmptyPersona() {
        let prompt = PromptBuilder.buildPrompt(
            template: "写日记",
            date: Date(),
            locationName: nil,
            persona: "   "
        )
        XCTAssertFalse(prompt.contains("作者背景与文风"))
    }

    func testDaySummaryPromptAppendsPersona() {
        let entries = [DiaryEntry(createdAt: Date(), text: "a", locationName: "公园")]
        let prompt = PromptBuilder.buildDaySummaryPrompt(
            template: "共 {count} 个瞬间：\n{timeline}",
            entries: entries,
            persona: "画像内容"
        )
        XCTAssertTrue(prompt.contains("共 1 个瞬间"))
        XCTAssertTrue(prompt.contains("作者背景与文风"))
        XCTAssertTrue(prompt.contains("画像内容"))
    }
}

final class DiaryStatsTests: XCTestCase {

    private func entry(_ text: String, location: String? = nil, lat: Double? = nil, lon: Double? = nil,
                       summary: Bool = false, title: String? = nil, tags: [String] = []) -> DiaryEntry {
        DiaryEntry(createdAt: Date(), text: text, locationName: location, latitude: lat, longitude: lon,
                   isDaySummary: summary, title: title, tags: tags)
    }

    private var sampleDays: [DiaryDay] {
        [
            DiaryDay(key: "2026-10-08", entries: [
                entry("傍晚又去公园", location: "静安公园", lat: 31.2, lon: 121.4, title: "银杏黄了", tags: ["公园", "秋天"]),
                entry("月小结", summary: true, tags: ["不计入"]),
            ]),
            DiaryDay(key: "2026-10-01", entries: [
                entry("上午在公园", location: "静安公园", tags: ["公园"]),
            ]),
            DiaryDay(key: "2026-09-15", entries: [
                entry("吃了一顿火锅", location: "海底捞", lat: 31.1, lon: 121.3, tags: ["火锅"]),
                entry("无坐标的一条"),
            ]),
        ]
    }

    func testTagCloudCountsOrderAndExcludesSummary() {
        let cloud = DiaryStats.tagCloud(days: sampleDays)
        // 同次数按 Unicode 字典序：火(U+706B) < 秋(U+79CB)
        XCTAssertEqual(cloud.map(\.tag), ["公园", "火锅", "秋天"])
        XCTAssertEqual(cloud.first?.count, 2)
        XCTAssertFalse(cloud.contains { $0.tag == "不计入" })
    }

    func testLocatedEntriesFiltersAndSorts() {
        let located = DiaryStats.locatedEntries(days: sampleDays)
        XCTAssertEqual(located.count, 2)
        XCTAssertEqual(located.map(\.dayKey), ["2026-09-15", "2026-10-08"]) // 按天升序
    }

    func testMonthlyGroups() {
        let groups = DiaryStats.monthlyGroups(days: sampleDays)
        XCTAssertEqual(groups.map(\.month), ["2026-10", "2026-09"]) // 降序
        XCTAssertEqual(groups[0].dayCount, 2)
        XCTAssertEqual(groups[0].entryCount, 2) // 小结不计入
        XCTAssertEqual(groups[1].dayCount, 1)
        XCTAssertEqual(groups[1].entryCount, 2)
    }

    func testInsight() {
        let insight = DiaryStats.insight(days: sampleDays)
        XCTAssertEqual(insight.dayCount, 3)
        XCTAssertEqual(insight.entryCount, 4)
        XCTAssertEqual(insight.topLocation, "静安公园")
        XCTAssertEqual(insight.topTags.first, "公园")
        XCTAssertEqual(insight.topTags.count, 3)
    }

    func testBuildMonthlySummaryPrompt() {
        let prompt = PromptBuilder.buildMonthlySummaryPrompt(
            template: "月份 {month} 共 {count} 条：\n{timeline}",
            month: "2026年10月",
            days: sampleDays,
            persona: "画像内容"
        )
        XCTAssertTrue(prompt.contains("月份 2026年10月 共 4 条"))
        XCTAssertTrue(prompt.contains("10-08 银杏黄了")) // 标题优先
        XCTAssertTrue(prompt.contains("09-15 吃了一顿火锅"))
        XCTAssertFalse(prompt.contains("月小结")) // 小结不进 timeline
        XCTAssertTrue(prompt.contains("作者背景与文风"))
    }

    func testBuildMonthlySummaryPromptTruncatesLongFirstLine() {
        let longText = String(repeating: "很长的正文。", count: 20)
        let days = [DiaryDay(key: "2026-10-01", entries: [entry(longText)])]
        let prompt = PromptBuilder.buildMonthlySummaryPrompt(
            template: "{timeline}", month: "2026年10月", days: days
        )
        // 正文首行截断到 30 字
        XCTAssertTrue(prompt.contains(String(longText.prefix(30))))
        XCTAssertFalse(prompt.contains(String(longText.prefix(31))))
    }
}
