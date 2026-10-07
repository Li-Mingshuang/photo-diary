import Foundation

/// 用拍摄信息填充 prompt 模板中的占位符
enum PromptBuilder {
    /// 支持的占位符：{datetime}、{date}、{time}、{location}
    static func buildPrompt(template: String, date: Date, locationName: String?) -> String {
        let datetimeFormatter = DateFormatter()
        datetimeFormatter.locale = Locale(identifier: "zh_CN")
        datetimeFormatter.dateFormat = "yyyy年M月d日 HH:mm"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        // 注意先替换 {datetime}，避免与 {date} 混淆
        return template
            .replacingOccurrences(of: "{datetime}", with: datetimeFormatter.string(from: date))
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{location}", with: locationName ?? "未知")
    }

    /// 「当日小结」prompt：填充照片数量与逐条时间线
    static func buildDaySummaryPrompt(template: String, entries: [DiaryEntry]) -> String {
        let timeline = entries
            .sorted { $0.createdAt < $1.createdAt }
            .map { entry in
                var line = "- \(entry.timeString)"
                if let location = entry.locationName, !location.isEmpty {
                    line += " · \(location)"
                }
                return line
            }
            .joined(separator: "\n")
        return template
            .replacingOccurrences(of: "{count}", with: "\(entries.count)")
            .replacingOccurrences(of: "{timeline}", with: timeline)
    }
}
