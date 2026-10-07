import SwiftUI

@main
struct PhotoDiaryApp: App {
    init() {
        // UI 测试钩子：带 -UITestResetData 启动时清空本地日记数据，
        // 保证每个 UI 用例独立、可重复、互不依赖执行顺序
        if ProcessInfo.processInfo.arguments.contains("-UITestResetData") {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("diaries"))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
