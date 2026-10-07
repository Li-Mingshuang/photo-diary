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

    func testDayKeyHelpers() {
        let date = makeDate("2026-10-07", "23:59")
        XCTAssertEqual(DayKey.key(for: date), "2026-10-07")
        XCTAssertEqual(DayKey.title(for: "2026-10-07"), "10月7日 星期三")
        XCTAssertTrue(DiaryStore.isValidDayKey("2026-10-07"))
        XCTAssertFalse(DiaryStore.isValidDayKey("2026-1-7"))
        XCTAssertFalse(DiaryStore.isValidDayKey("随便什么"))
    }
}
