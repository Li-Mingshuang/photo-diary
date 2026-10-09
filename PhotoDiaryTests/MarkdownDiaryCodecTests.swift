import XCTest
@testable import PhotoDiary

final class MarkdownDiaryCodecTests: XCTestCase {

    private func makeDate(_ dayKey: String, _ time: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: "\(dayKey) \(time)")!
    }

    func testRenderAndParseRoundTrip() {
        let dayKey = "2026-10-07"
        var entry1 = DiaryEntry(
            createdAt: makeDate(dayKey, "14:30"),
            text: "下午在公园散步，阳光很好。\n银杏叶开始黄了。",
            imageFileName: "IMG_20261007-143000-ab12cd34.jpg",
            locationName: "上海市 · 静安区 · 静安公园"
        )
        entry1.id = UUID()
        var entry2 = DiaryEntry(
            createdAt: makeDate(dayKey, "20:05"),
            text: "晚上随手拍的一张照片。",
            imageFileName: nil,
            locationName: nil
        )
        entry2.id = UUID()

        let markdown = MarkdownDiaryCodec.render(dayKey: dayKey, entries: [entry2, entry1]) // 故意乱序

        XCTAssertTrue(markdown.hasPrefix("# 2026年10月7日 星期三"))
        XCTAssertTrue(markdown.contains("## 14:30 · 上海市 · 静安区 · 静安公园"))
        XCTAssertTrue(markdown.contains("![照片](images/IMG_20261007-143000-ab12cd34.jpg)"))
        XCTAssertTrue(markdown.contains("---"))

        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: dayKey)
        XCTAssertEqual(parsed.count, 2)

        // 解析结果应按时间升序
        XCTAssertEqual(parsed[0].timeString, "14:30")
        XCTAssertEqual(parsed[0].text, entry1.text)
        XCTAssertEqual(parsed[0].imageFileName, entry1.imageFileName)
        XCTAssertEqual(parsed[0].locationName, entry1.locationName)

        XCTAssertEqual(parsed[1].timeString, "20:05")
        XCTAssertEqual(parsed[1].text, entry2.text)
        XCTAssertNil(parsed[1].imageFileName)
        XCTAssertNil(parsed[1].locationName)
    }

    func testParseKeepsMultilineText() {
        let markdown = """
        # 2026年10月7日 星期三

        ## 09:15 · 某地

        第一行
        第二行

        第三段

        ---
        """
        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: "2026-10-07")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, "第一行\n第二行\n\n第三段")
    }

    func testParseIgnoresLeadingGarbageAndTitle() {
        let markdown = """
        # 2026年10月7日 星期三

        一些不属于任何条目的文字

        ## 08:00

        早上好
        """
        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: "2026-10-07")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, "早上好")
    }

    func testEntryHeaderParsing() {
        let withLocation = MarkdownDiaryCodec.parseEntryHeader("## 14:30 · 上海市 · 静安公园")
        XCTAssertEqual(withLocation?.time.hour, 14)
        XCTAssertEqual(withLocation?.time.minute, 30)
        XCTAssertEqual(withLocation?.location, "上海市 · 静安公园")

        let withoutLocation = MarkdownDiaryCodec.parseEntryHeader("## 08:05")
        XCTAssertEqual(withoutLocation?.time.hour, 8)
        XCTAssertNil(withoutLocation?.location)

        XCTAssertNil(MarkdownDiaryCodec.parseEntryHeader("# 标题"))
        XCTAssertNil(MarkdownDiaryCodec.parseEntryHeader("## 不是时间"))
        XCTAssertNil(MarkdownDiaryCodec.parseEntryHeader("## 25:00"))
    }

    func testImageLineParsing() {
        XCTAssertEqual(
            MarkdownDiaryCodec.parseImageLine("![照片](images/IMG_1.jpg)"),
            "IMG_1.jpg"
        )
        XCTAssertNil(MarkdownDiaryCodec.parseImageLine("普通文本"))
        XCTAssertNil(MarkdownDiaryCodec.parseImageLine("![照片](other/IMG_1.jpg)"))
    }

    func testTimestampCommentRoundTripPreservesExactInstant() {
        let dayKey = "2026-10-07"
        // 带秒和非零时区的精确时间
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 7
        components.hour = 14; components.minute = 30; components.second = 45
        components.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        let exactDate = Calendar(identifier: .gregorian).date(from: components)!

        let entry = DiaryEntry(createdAt: exactDate, text: "精确时间")
        let markdown = MarkdownDiaryCodec.render(dayKey: dayKey, entries: [entry])
        // 注释行存在（具体时区取决于写入时本机时区，不做硬断言）
        XCTAssertTrue(markdown.contains("<!-- "))
        XCTAssertTrue(markdown.contains(" -->"))

        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: dayKey)
        XCTAssertEqual(parsed.count, 1)
        // 时间戳精确到秒，不受 HH:mm 精度影响
        XCTAssertEqual(parsed[0].createdAt.timeIntervalSince1970, exactDate.timeIntervalSince1970, accuracy: 0.5)
    }

    func testEscapeConflictingTextLinesRoundTrip() {
        let dayKey = "2026-10-07"
        let trickyText = """
        正常一行
        ---
        ## 12:00 · 伪装的标题
        ![伪装的图片](images/fake.jpg)
        最后一行
        """
        let entry = DiaryEntry(createdAt: makeDate(dayKey, "10:00"), text: trickyText)
        let markdown = MarkdownDiaryCodec.render(dayKey: dayKey, entries: [entry])

        // 冲突行被转义
        XCTAssertTrue(markdown.contains("\\---"))
        XCTAssertTrue(markdown.contains("\\## 12:00 · 伪装的标题"))
        XCTAssertTrue(markdown.contains("\\![伪装的图片](images/fake.jpg)"))

        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: dayKey)
        // 不会被误判为两个条目
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, trickyText)
    }

    func testDaySummaryRenderAndParseRoundTrip() {
        let dayKey = "2026-10-07"
        let summary = DiaryEntry(
            createdAt: makeDate(dayKey, "23:59"),
            text: "今天是充实的一天，上午爬山下午看海。",
            isDaySummary: true
        )
        let regular = DiaryEntry(
            createdAt: makeDate(dayKey, "14:30"),
            text: "下午在公园散步。",
            imageFileName: "IMG_1.jpg",
            locationName: "公园"
        )
        let markdown = MarkdownDiaryCodec.render(dayKey: dayKey, entries: [regular, summary])

        // 小结渲染在最前面
        let summaryRange = markdown.range(of: "## 当日小结")!
        let regularRange = markdown.range(of: "## 14:30 · 公园")!
        XCTAssertTrue(summaryRange.lowerBound < regularRange.lowerBound)

        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: dayKey)
        XCTAssertEqual(parsed.count, 2)
        // 排序：小结在前
        XCTAssertTrue(parsed[0].isDaySummary)
        XCTAssertEqual(parsed[0].text, summary.text)
        XCTAssertEqual(parsed[0].timeString, "23:59")
        XCTAssertFalse(parsed[1].isDaySummary)
        XCTAssertEqual(parsed[1].text, regular.text)
    }

    func testEscapeSummaryHeaderInText() {
        // 正文里出现「## 当日小结」也要转义
        let line = "## 当日小结"
        XCTAssertEqual(MarkdownDiaryCodec.escapeTextLine(line), "\\## 当日小结")
        let markdown = """
        ## 10:00

        \\## 当日小结
        """
        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: "2026-10-07")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertFalse(parsed[0].isDaySummary)
        XCTAssertEqual(parsed[0].text, "## 当日小结")
    }

    // MARK: - DiarySearch

    private func makeDay(_ key: String, _ texts: [(String, String?)]) -> DiaryDay {
        DiaryDay(key: key, entries: texts.enumerated().map { index, item in
            DiaryEntry(
                createdAt: makeDate(key, String(format: "%02d:00", 9 + index)),
                text: item.0,
                locationName: item.1
            )
        })
    }

    func testSearchFilter() {
        let days = [
            makeDay("2026-10-07", [("下午在公园散步", "静安公园"), ("晚上吃火锅", "海底捞")]),
            makeDay("2026-10-06", [("在家看书", nil)]),
        ]
        // 空查询返回全部
        XCTAssertEqual(DiarySearch.filter(days, query: "  ").count, 2)
        // 按正文
        let byText = DiarySearch.filter(days, query: "火锅")
        XCTAssertEqual(byText.count, 1)
        XCTAssertEqual(byText[0].entries.count, 1)
        XCTAssertEqual(byText[0].entries[0].text, "晚上吃火锅")
        // 按地点
        let byLocation = DiarySearch.filter(days, query: "静安")
        XCTAssertEqual(byLocation.count, 1)
        XCTAssertEqual(byLocation[0].entries[0].locationName, "静安公园")
        // 按日期键
        let byDate = DiarySearch.filter(days, query: "10-06")
        XCTAssertEqual(byDate.count, 1)
        XCTAssertEqual(byDate[0].key, "2026-10-06")
        // 无命中
        XCTAssertTrue(DiarySearch.filter(days, query: "不存在的词").isEmpty)
    }

    func testTitleAndTagsRoundTrip() {
        let dayKey = "2026-10-07"
        let entry = DiaryEntry(
            createdAt: makeDate(dayKey, "14:30"),
            text: "下午在公园散步。",
            imageFileName: "IMG_1.jpg",
            locationName: "公园",
            title: "银杏叶黄了",
            tags: ["公园", "秋天"]
        )
        let markdown = MarkdownDiaryCodec.render(dayKey: dayKey, entries: [entry])
        XCTAssertTrue(markdown.contains("title: 银杏叶黄了"))
        XCTAssertTrue(markdown.contains("tags: #公园 #秋天"))

        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: dayKey)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "银杏叶黄了")
        XCTAssertEqual(parsed[0].tags, ["公园", "秋天"])
        XCTAssertEqual(parsed[0].text, "下午在公园散步。")
    }

    func testMarkerLinesEscapedInText() {
        // 正文里出现 title:/tags: 开头的行要转义还原
        let dayKey = "2026-10-07"
        let tricky = "title: 这是正文不是标题\ntags: 同上"
        let entry = DiaryEntry(createdAt: makeDate(dayKey, "10:00"), text: tricky)
        let markdown = MarkdownDiaryCodec.render(dayKey: dayKey, entries: [entry])
        XCTAssertTrue(markdown.contains("\\title: 这是正文不是标题"))
        let parsed = MarkdownDiaryCodec.parse(markdown, dayKey: dayKey)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertNil(parsed[0].title)
        XCTAssertTrue(parsed[0].tags.isEmpty)
        XCTAssertEqual(parsed[0].text, tricky)
    }

    func testSearchMatchesTitleAndTags() {
        let entry = DiaryEntry(
            createdAt: makeDate("2026-10-07", "09:00"),
            text: "今天天气不错",
            title: "银杏叶黄了",
            tags: ["公园", "秋天"]
        )
        let days = [DiaryDay(key: "2026-10-07", entries: [entry])]
        XCTAssertEqual(DiarySearch.filter(days, query: "银杏").count, 1)   // 按标题
        XCTAssertEqual(DiarySearch.filter(days, query: "秋天").count, 1)   // 按标签
        XCTAssertEqual(DiarySearch.filter(days, query: "#公园").count, 1)  // 带 # 前缀搜标签
        XCTAssertTrue(DiarySearch.filter(days, query: "不相关").isEmpty)
    }

    func testDayKeyHelpers() {
        let date = makeDate("2026-10-07", "23:59")
        XCTAssertEqual(DayKey.key(for: date), "2026-10-07")
        XCTAssertEqual(DayKey.title(for: "2026-10-07"), "10月7日 星期三")
        XCTAssertTrue(DiaryStore.isValidDayKey("2026-10-07"))
        XCTAssertFalse(DiaryStore.isValidDayKey("2026-1-7"))
        XCTAssertFalse(DiaryStore.isValidDayKey("随便什么"))
    }
}

final class MonthlySummaryCodecTests: XCTestCase {

    func testRenderAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("monthly-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let markdown = MonthlySummaryCodec.render(
            monthKey: "2026-10",
            text: "这个月去了很多次公园。\n银杏黄了，人也慢下来了。",
            generatedAt: date, model: "deepseek-flash", entryCount: 12
        )
        XCTAssertTrue(markdown.contains("# 2026年10月 · 月记"))
        XCTAssertTrue(markdown.contains("model: deepseek-flash"))
        XCTAssertTrue(markdown.contains("entries: 12"))

        let url = dir.appendingPathComponent("2026-10.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let loaded = MonthlySummaryCodec.load(from: url)
        XCTAssertEqual(loaded?.text, "这个月去了很多次公园。\n银杏黄了，人也慢下来了。")
        XCTAssertEqual(loaded?.model, "deepseek-flash")
        XCTAssertEqual(loaded?.entryCount, 12)
        XCTAssertEqual(loaded?.generatedAt?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
    }

    func testMonthTitle() {
        XCTAssertEqual(MonthlySummaryCodec.monthTitle(for: "2026-10"), "2026年10月")
        XCTAssertEqual(MonthlySummaryCodec.monthTitle(for: "2026-01"), "2026年1月")
        XCTAssertEqual(MonthlySummaryCodec.monthTitle(for: "2026-13"), "2026-13")
        XCTAssertEqual(MonthlySummaryCodec.monthTitle(for: "随便"), "随便")
    }

    func testLoadMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).md")
        XCTAssertNil(MonthlySummaryCodec.load(from: url))
    }

    func testLoadEmptyBodyReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("monthly-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("2026-10.md")
        try "# 2026年10月 · 月记\n\n<!-- generated: 2026-10-08T17:00:00+08:00 · model: m · entries: 3 -->\n\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(MonthlySummaryCodec.load(from: url))
    }
}
