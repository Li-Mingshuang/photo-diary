import XCTest
import UIKit
@testable import PhotoDiary

@MainActor
final class DiaryStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: DiaryStore!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiaryStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = DiaryStore(rootURL: tempRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    private func makeDate(_ dayKey: String, _ time: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(dayKey) \(time)")!
    }

    func testAddEntryPersistsMarkdownAndImage() throws {
        let entry = DiaryEntry(
            createdAt: makeDate("2026-10-07", "14:30"),
            text: "测试日记内容",
            locationName: "测试地点"
        )
        let saved = try store.addEntry(entry, image: makeImage())

        // 内存状态
        XCTAssertEqual(store.days.count, 1)
        XCTAssertEqual(store.days[0].key, "2026-10-07")
        XCTAssertEqual(store.days[0].entries.count, 1)

        // md 文件
        let mdURL = store.markdownURL(forDayKey: "2026-10-07")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))
        let markdown = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## 14:30 · 测试地点"))
        XCTAssertTrue(markdown.contains("测试日记内容"))

        // 图片文件
        let imageName = try XCTUnwrap(saved.imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: imageName).path))
        XCTAssertTrue(markdown.contains("![照片](images/\(imageName))"))
    }

    func testReloadRestoresEntries() throws {
        _ = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-07", "09:00"), text: "早上", locationName: "家"),
            image: makeImage()
        )
        _ = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-07", "21:00"), text: "晚上"),
            image: nil
        )
        _ = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-06", "12:00"), text: "昨天的"),
            image: nil
        )

        // 重新建一个 store，从磁盘恢复
        let reloaded = DiaryStore(rootURL: tempRoot)
        XCTAssertEqual(reloaded.days.count, 2)
        // 按天倒序
        XCTAssertEqual(reloaded.days[0].key, "2026-10-07")
        XCTAssertEqual(reloaded.days[1].key, "2026-10-06")

        let today = reloaded.days[0]
        XCTAssertEqual(today.entries.count, 2)
        XCTAssertEqual(today.entries[0].timeString, "09:00")
        XCTAssertEqual(today.entries[0].text, "早上")
        XCTAssertEqual(today.entries[0].locationName, "家")
        XCTAssertNotNil(today.entries[0].imageFileName)
        XCTAssertEqual(today.entries[1].text, "晚上")
        XCTAssertNil(today.entries[1].imageFileName)
    }

    func testUpdateEntryPersists() throws {
        let saved = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-07", "14:30"), text: "原文"),
            image: nil
        )
        var updated = saved
        updated.text = "改过的文字"
        store.updateEntry(updated)

        let reloaded = DiaryStore(rootURL: tempRoot)
        XCTAssertEqual(reloaded.days[0].entries[0].text, "改过的文字")
    }

    func testDeleteEntryRemovesFilesWhenDayBecomesEmpty() throws {
        let saved = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-07", "14:30"), text: "将被删除"),
            image: makeImage()
        )
        let imageName = try XCTUnwrap(saved.imageFileName)

        store.deleteEntry(saved)

        XCTAssertTrue(store.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.markdownURL(forDayKey: "2026-10-07").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: imageName).path))
    }

    func testDeleteOneOfTwoKeepsMarkdown() throws {
        let first = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-07", "09:00"), text: "第一条"),
            image: nil
        )
        _ = try store.addEntry(
            DiaryEntry(createdAt: makeDate("2026-10-07", "20:00"), text: "第二条"),
            image: nil
        )
        store.deleteEntry(first)

        XCTAssertEqual(store.days.count, 1)
        XCTAssertEqual(store.days[0].entries.count, 1)
        XCTAssertEqual(store.days[0].entries[0].text, "第二条")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.markdownURL(forDayKey: "2026-10-07").path))
    }
}
