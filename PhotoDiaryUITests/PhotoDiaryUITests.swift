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
        app.launchArguments = ["-UITestResetData"]
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
        // 冷启动的 picker 网格还在加载时 AX 滚动会失败（kAXErrorCannotComplete），
        // 等网格稳定后用坐标点击（与工具栏 Menu 同款解法）
        sleep(2)
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

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
        // （注意不能用 cells.firstMatch：未配 Key 时列表首行是引导横幅）
        app.navigationBars["新日记"].buttons["保存"].tap()
        let dayCell = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "条记录")).firstMatch
        XCTAssertTrue(dayCell.waitForExistence(timeout: 5))
        save("05-home-with-diary")

        // 8. 进入日记详情页（含分享导出按钮）
        dayCell.tap()
        sleep(1)
        save("06-day-detail")

        // 详情页应展示刚写的正文
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "银杏叶")).firstMatch.waitForExistence(timeout: 3))
    }

    /// 迭代二功能截图：首次引导、去设置入口、Key 横幅、搜索、当日小结按钮。
    /// 通过 -UITestResetData 启动参数清空数据，与 testFullFlow 相互独立。
    @MainActor
    func testIteration2FeaturesWithScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetData"]
        app.launch()

        // 1. 全新安装空态：ContentUnavailableView 带「先设置 API Key」主按钮
        XCTAssertTrue(app.navigationBars["光影日记"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["先设置 API Key"].waitForExistence(timeout: 3))
        save("10-empty-onboarding")

        // 2. 导入照片 → 新增页：无 Key 报错 + 「去设置 API Key」入口
        let addMenu = app.buttons["addEntryMenu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 3))
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let importButton = app.buttons["从相册导入"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        importButton.tap()
        let firstPhoto = app.scrollViews.images.element(boundBy: 0)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        // 冷启动的 picker 网格还在加载时 AX 滚动会失败（kAXErrorCannotComplete），
        // 等网格稳定后用坐标点击（与工具栏 Menu 同款解法）
        sleep(2)
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.navigationBars["新日记"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["去设置 API Key"].waitForExistence(timeout: 5))
        save("11-add-entry-nokey")

        // 3. 写正文保存 → 首页：顶部常驻「未设置 Key」引导横幅
        let editor = app.textViews["diaryTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("傍晚去江边看了日落，风很舒服。")
        app.navigationBars["新日记"].buttons["保存"].tap()
        let dayCell = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "条记录")).firstMatch
        XCTAssertTrue(dayCell.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "还没有设置 API Key")).firstMatch.exists)
        save("12-home-banner")

        // 4. 搜索：无命中 → ContentUnavailableView.search
        app.swipeDown() // 下拉露出搜索框
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("火锅")
        sleep(1)
        // 无命中：日记行消失（无结果空态文案随系统语言变化，不硬断言文案）
        XCTAssertFalse(app.cells.containing(NSPredicate(format: "label CONTAINS %@", "条记录")).firstMatch.exists)
        save("13-search-empty")

        // 5. 搜索：清空后搜命中词 → 只显示命中的天
        searchField.tap()
        app.buttons["Clear text"].firstMatch.tapIfExists()
        app.buttons["清除文本"].firstMatch.tapIfExists()
        if let value = searchField.value as? String, value.contains("火锅") {
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        searchField.typeText("日落")
        sleep(1)
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label CONTAINS %@", "日落")).firstMatch.waitForExistence(timeout: 3))
        save("14-search-result")
        app.buttons["Cancel"].firstMatch.tapIfExists()
        app.buttons["取消"].firstMatch.tapIfExists()

        // 6. 日记详情：工具栏有「当日小结」与分享按钮
        let cell2 = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "条记录")).firstMatch
        XCTAssertTrue(cell2.waitForExistence(timeout: 5))
        cell2.tap()
        sleep(1)
        XCTAssertTrue(app.buttons["daySummaryButton"].waitForExistence(timeout: 3))
        save("15-day-detail-toolbar")

        // 7. 点「当日小结」：无 Key → 弹窗提示
        app.buttons["daySummaryButton"].tap()
        XCTAssertTrue(app.alerts["操作失败"].waitForExistence(timeout: 3))
        save("16-summary-nokey-alert")
        app.alerts["操作失败"].buttons["好的"].tap()

        // 8. 条目菜单：编辑 / 重新生成 / 删除
        let entryMenu = app.buttons["entryMenuButton"].firstMatch
        XCTAssertTrue(entryMenu.waitForExistence(timeout: 3))
        entryMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(app.buttons["重新生成"].waitForExistence(timeout: 3))
        save("17-entry-menu")
    }

    /// 迭代五：回顾 Tab——空态引导、统计洞察卡、月度区（无 Key 时生成按钮禁用）。
    @MainActor
    func testReviewTabWithScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetData"]
        app.launch()

        // 1. 空数据时回顾 Tab 显示引导空态
        XCTAssertTrue(app.navigationBars["光影日记"].waitForExistence(timeout: 5))
        app.tabBars.buttons["回顾"].tap()
        XCTAssertTrue(app.navigationBars["回顾"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["还没有可回顾的内容"].waitForExistence(timeout: 3))
        save("18-review-empty")

        // 2. 回「日记」Tab 造一条日记
        app.tabBars.buttons["日记"].tap()
        let addMenu = app.buttons["addEntryMenu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 3))
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let importButton = app.buttons["从相册导入"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        importButton.tap()
        let firstPhoto = app.scrollViews.images.element(boundBy: 0)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        sleep(2) // picker 网格稳定（同 testFullFlow 的坐标点击解法）
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let editor = app.textViews["diaryTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("在公园看了一下午银杏。")
        app.navigationBars["新日记"].buttons["保存"].tap()
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label CONTAINS %@", "条记录")).firstMatch.waitForExistence(timeout: 5))

        // 3. 回顾 Tab：洞察卡 + 月度区（无 Key 时「生成月记」仍可见，点进去按钮禁用）
        app.tabBars.buttons["回顾"].tap()
        XCTAssertTrue(app.staticTexts["1 天 · 1 条记录"].waitForExistence(timeout: 3))
        // 无标签/无坐标数据时标签墙与地图区块优雅隐藏
        XCTAssertFalse(app.staticTexts["标签墙"].exists)
        XCTAssertFalse(app.staticTexts["足迹地图"].exists)
        save("19-review-insight")

        XCTAssertTrue(app.staticTexts["月度回顾"].waitForExistence(timeout: 3))
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "生成月记")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars.containing(NSPredicate(format: "label CONTAINS %@", "月记")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.buttons["生成"].isEnabled) // 无 Key 禁用
        save("20-review-monthly-nokey")
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: "\(shotDir)/\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if exists { tap() }
    }
}
