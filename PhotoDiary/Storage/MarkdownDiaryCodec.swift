import Foundation

/// 日记 Markdown 格式（每天一个文件，例 2026-10-07.md）：
///
///     # 2026年10月7日 星期三
///
///     ## 14:30 · 上海市 · 静安区 · 静安公园
///
///     ![照片](images/IMG_20261007-143000-ab12cd34.jpg)
///
///     日记正文，可以多行。
///
///     ---
///
/// 解析时对无法识别的行尽量容错跳过。
///
/// 补充约定：
/// - 条目标题下紧跟一行 HTML 注释 `<!-- 2026-10-07T14:30:00+08:00 -->`，保存带时区的精确时间，
///   解析时优先于 `HH:mm`（解决跨时区/秒精度问题），人读文件时不受影响；
/// - 正文里与语法冲突的行（`---`、`## HH:mm`、`![..](images/..)`）渲染时加 `\\` 前缀转义，解析时还原。
enum MarkdownDiaryCodec {

    /// 带时区的精确时间格式，如 2026-10-07T14:30:00+08:00
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 「当日小结」的条目标题
    static let summaryHeader = "## 当日小结"

    // MARK: - 渲染

    static func render(dayKey: String, entries: [DiaryEntry]) -> String {
        var lines: [String] = []
        lines.append("# \(titleLine(for: dayKey))")
        lines.append("")

        // 当日小结排在最前，普通条目按时间升序
        let sorted = entries.sorted {
            ($0.isDaySummary ? 0 : 1, $0.createdAt) < ($1.isDaySummary ? 0 : 1, $1.createdAt)
        }

        var blocks: [String] = []
        for entry in sorted {
            var block: [String] = []
            if entry.isDaySummary {
                block.append(summaryHeader)
            } else {
                var header = "## \(entry.timeString)"
                if let location = entry.locationName, !location.isEmpty {
                    header += " · \(location)"
                }
                block.append(header)
            }
            block.append("")
            // 隐藏行：带时区的精确时间戳
            block.append("<!-- \(isoFormatter.string(from: entry.createdAt)) -->")
            block.append("")
            if let imageName = entry.imageFileName {
                block.append("![照片](images/\(imageName))")
                block.append("")
            }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let escaped = text
                    .components(separatedBy: .newlines)
                    .map { escapeTextLine($0) }
                    .joined(separator: "\n")
                block.append(escaped)
                block.append("")
            }
            blocks.append(block.joined(separator: "\n"))
        }
        lines.append(blocks.joined(separator: "---\n\n"))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func titleLine(for dayKey: String) -> String {
        guard let date = DayKey.date(for: dayKey) else { return dayKey }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    // MARK: - 解析

    static func parse(_ markdown: String, dayKey: String) -> [DiaryEntry] {
        guard let dayStart = DayKey.date(for: dayKey) else { return [] }
        let calendar = Calendar.current

        var entries: [DiaryEntry] = []
        var current: DiaryEntry?
        var textLines: [String] = []

        func flushCurrent() {
            guard var entry = current else { return }
            // 去掉正文首尾空行
            while textLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                textLines.removeFirst()
            }
            while textLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                textLines.removeLast()
            }
            entry.text = textLines.joined(separator: "\n")
            entries.append(entry)
            current = nil
            textLines = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line == summaryHeader {
                flushCurrent()
                var components = calendar.dateComponents([.year, .month, .day], from: dayStart)
                components.hour = 23
                components.minute = 59
                current = DiaryEntry(
                    createdAt: calendar.date(from: components) ?? dayStart,
                    text: "",
                    imageFileName: nil,
                    locationName: nil,
                    isDaySummary: true
                )
                continue
            }

            if let (time, location) = parseEntryHeader(line) {
                flushCurrent()
                var components = calendar.dateComponents([.year, .month, .day], from: dayStart)
                components.hour = time.hour
                components.minute = time.minute
                let createdAt = calendar.date(from: components) ?? dayStart
                current = DiaryEntry(
                    createdAt: createdAt,
                    text: "",
                    imageFileName: nil,
                    locationName: location
                )
                continue
            }

            guard current != nil else { continue } // 忽略条目标题之前的内容（如文档标题）

            // 隐藏 ISO 时间戳行：优先作为条目的精确时间
            if let timestamp = parseTimestampComment(line) {
                current?.createdAt = timestamp
                continue
            }

            // 转义行：还原为普通正文
            if line.hasPrefix("\\") {
                let unescaped = String(line.dropFirst())
                if unescaped == "---" || unescaped == summaryHeader || parseEntryHeader(unescaped) != nil || parseImageLine(unescaped) != nil {
                    textLines.append(unescaped)
                    continue
                }
            }

            if let imageName = parseImageLine(line) {
                current?.imageFileName = imageName
                continue
            }

            if line == "---" {
                flushCurrent()
                continue
            }

            textLines.append(rawLine)
        }
        flushCurrent()

        // 与渲染保持一致：当日小结在前，普通条目按时间升序
        return entries.sorted {
            ($0.isDaySummary ? 0 : 1, $0.createdAt) < ($1.isDaySummary ? 0 : 1, $1.createdAt)
        }
    }

    /// 解析 `<!-- 2026-10-07T14:30:00+08:00 -->` 时间戳注释行
    static func parseTimestampComment(_ line: String) -> Date? {
        guard line.hasPrefix("<!-- "), line.hasSuffix(" -->") else { return nil }
        let inner = line.dropFirst(5).dropLast(4)
        return isoFormatter.date(from: String(inner))
    }

    /// 正文行若与日记语法冲突（分隔线/条目标题/小结标题/图片行），加反斜杠转义
    static func escapeTextLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" || trimmed == summaryHeader || parseEntryHeader(trimmed) != nil || parseImageLine(trimmed) != nil {
            return "\\" + line
        }
        return line
    }

    /// 匹配 `## 14:30` 或 `## 14:30 · 某地`
    static func parseEntryHeader(_ line: String) -> (time: (hour: Int, minute: Int), location: String?)? {
        guard line.hasPrefix("## ") else { return nil }
        let rest = String(line.dropFirst(3))
        // 时间与地点用第一个「·」分隔
        let parts = rest.components(separatedBy: "·")
        let timePart = parts[0].trimmingCharacters(in: .whitespaces)
        let timePieces = timePart.split(separator: ":")
        guard timePieces.count == 2,
              let hour = Int(timePieces[0]), (0..<24).contains(hour),
              let minute = Int(timePieces[1]), (0..<60).contains(minute) else {
            return nil
        }
        var location: String?
        if parts.count > 1 {
            let loc = parts.dropFirst().joined(separator: "·").trimmingCharacters(in: .whitespaces)
            location = loc.isEmpty ? nil : loc
        }
        return ((hour, minute), location)
    }

    /// 匹配 `![任意](images/xxx.jpg)`
    static func parseImageLine(_ line: String) -> String? {
        guard line.hasPrefix("!["), let range = line.range(of: "](images/"), line.hasSuffix(")") else {
            return nil
        }
        let nameStart = range.upperBound
        let name = String(line[nameStart...].dropLast())
        return name.isEmpty ? nil : name
    }
}
