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
