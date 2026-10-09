import Foundation

/// 用拍摄信息填充 prompt 模板中的占位符
enum PromptBuilder {
    /// 支持的占位符：{datetime}、{date}、{time}、{location}；persona 非空时在末尾追加作者画像段
    static func buildPrompt(template: String, date: Date, locationName: String?, persona: String? = nil) -> String {
        let datetimeFormatter = DateFormatter()
        datetimeFormatter.locale = Locale(identifier: "zh_CN")
        datetimeFormatter.dateFormat = "yyyy年M月d日 HH:mm"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        // 注意先替换 {datetime}，避免与 {date} 混淆
        let base = template
            .replacingOccurrences(of: "{datetime}", with: datetimeFormatter.string(from: date))
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{location}", with: locationName ?? "未知")
        return appendingPersona(persona, to: base)
    }

    /// 「当日小结」prompt：填充照片数量与逐条时间线；persona 非空时追加画像段
    static func buildDaySummaryPrompt(template: String, entries: [DiaryEntry], persona: String? = nil) -> String {
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
        let base = template
            .replacingOccurrences(of: "{count}", with: "\(entries.count)")
            .replacingOccurrences(of: "{timeline}", with: timeline)
        return appendingPersona(persona, to: base)
    }

    /// 「月度回顾」prompt：{month} {count} {timeline}；timeline 为每天一行「MM-dd 标题或正文首行」，上限 40 行防超长
    static func buildMonthlySummaryPrompt(template: String, month: String, days: [DiaryDay], persona: String? = nil) -> String {
        var lines: [String] = []
        var count = 0
        for day in days.sorted(by: { $0.key < $1.key }) {
            for entry in day.entries where !entry.isDaySummary {
                count += 1
                let snippet = entry.title
                    ?? entry.text.components(separatedBy: .newlines).first
                        .map { String($0.prefix(30)) } ?? ""
                lines.append("\(day.key.suffix(5)) \(snippet)")
            }
        }
        if lines.count > 40 { lines = Array(lines.prefix(40)) }
        let base = template
            .replacingOccurrences(of: "{month}", with: month)
            .replacingOccurrences(of: "{count}", with: "\(count)")
            .replacingOccurrences(of: "{timeline}", with: lines.joined(separator: "\n"))
        return appendingPersona(persona, to: base)
    }

    /// 画像段统一追加在 prompt 末尾（自定义模板没有占位符也能生效）
    private static func appendingPersona(_ persona: String?, to prompt: String) -> String {
        let trimmed = persona?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return prompt }
        return prompt + "\n\n作者背景与文风（请以其视角与口吻写作，自然融入，不要直接提及这些信息）：\n" + trimmed
    }
}
