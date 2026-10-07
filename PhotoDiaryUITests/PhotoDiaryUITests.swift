import XCTest

/// 全流程 UI 测试：真实驱动模拟器走完各个环节并逐屏截图。
/// 前置条件：模拟器相册里至少有一张照片（用 `xcrun simctl addphoto` 注入）。
/// 截图落盘到 Mac 的 /tmp/photodiary-ui/（模拟器与 Mac 共享文件系统）。
final class PhotoDiaryUITests: XCTestCase {

    private let shotDir = "/tmp/photodiary-ui"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
    }

    @MainActor
    func testFullFlowWithScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. 首页（空态或已有内容）
        XCTAssertTrue(app.navigationBars["光影日记"].waitForExistence(timeout: 5))
        save("01-home")

        // 2. 设置页
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        save("02-settings")
        app.navigationBars["设置"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["光影日记"].waitForExistence(timeout: 3))

        // 3. 右上角 + → 从相册导入（SwiftUI Menu 在工具栏中不支持 AX 滚动，用坐标点击）
        let addMenu = app.buttons["addEntryMenu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 3))
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let importButton = app.buttons["从相册导入"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        importButton.tap()

        // 4. 系统照片选择器：选第一张（最新的一张）照片
        let firstPhoto = app.scrollViews.images.element(boundBy: 0)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()

        // 5. 新增页：未配置 API Key 时的降级提示（AI 生成自动触发后立刻报错兜底）
        XCTAssertTrue(app.navigationBars["新日记"].waitForExistence(timeout: 5))
        sleep(1)
        save("03-add-entry-fallback")

        // 6. 手动写一段日记
        let editor = app.textViews["diaryTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("今天下午在公园散步，阳光很好，银杏叶开始黄了，随手拍下了这一刻。")
        save("04-add-entry-editing")

        // 7. 保存回首页，出现当天的日记卡片
        app.navigationBars["新日记"].buttons["保存"].tap()
        let dayCell = app.cells.firstMatch
        XCTAssertTrue(dayCell.waitForExistence(timeout: 5))
        save("05-home-with-diary")

        // 8. 进入日记详情页（含分享导出按钮）
        dayCell.tap()
        sleep(1)
        save("06-day-detail")

        // 详情页应展示刚写的正文
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "银杏叶")).firstMatch.waitForExistence(timeout: 3))
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: "\(shotDir)/\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
