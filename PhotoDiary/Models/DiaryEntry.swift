import Foundation
import UIKit
import CoreLocation

/// 一天的日记键，格式 yyyy-MM-dd（本地时区）
enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func key(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(for key: String) -> Date? {
        formatter.date(from: key)
    }

    /// 中文标题，如「10月7日 星期三」
    static func title(for key: String) -> String {
        guard let date = date(for: key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: date)
    }
}

struct DiaryEntry: Identifiable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date
    var text: String
    var imageFileName: String?
    /// 语音日记的音频文件（audio/ 目录下，可选，老数据没有）
    var audioFileName: String?
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    /// 是否为「当日小结」（由当天多张照片合并生成，渲染在日记文件顶部）
    var isDaySummary: Bool = false
    /// AI 生成的简短标题（可选，老数据没有）
    var title: String? = nil
    /// AI 生成的标签（不含 # 前缀）
    var tags: [String] = []

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: createdAt)
    }
}

struct DiaryDay: Identifiable, Equatable {
    let key: String // yyyy-MM-dd
    var entries: [DiaryEntry]

    var id: String { key }
    var title: String { DayKey.title(for: key) }

    /// 列表行摘要：优先标题，其次正文首行
    var summary: String {
        guard let first = entries.first else { return "" }
        if let title = first.title, !title.isEmpty { return title }
        return first.text.components(separatedBy: .newlines).first ?? ""
    }
}

/// 日记搜索过滤（纯函数，便于测试）
enum DiarySearch {
    /// 按正文、地点、日期标题/键过滤；空查询返回全部。
    /// 命中的天仅保留命中的条目（日期本身命中则保留全部条目）。
    static func filter(_ days: [DiaryDay], query: String) -> [DiaryDay] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return days }
        // 带 # 前缀的查询同时按裸词匹配标签
        let tagQuery = q.hasPrefix("#") ? String(q.dropFirst()) : q
        return days.compactMap { day in
            if day.title.localizedCaseInsensitiveContains(q) || day.key.contains(q) {
                return day
            }
            let matched = day.entries.filter { entry in
                entry.text.localizedCaseInsensitiveContains(q)
                    || (entry.locationName?.localizedCaseInsensitiveContains(q) ?? false)
                    || (entry.title?.localizedCaseInsensitiveContains(q) ?? false)
                    || entry.tags.contains { $0.localizedCaseInsensitiveContains(tagQuery) }
            }
            return matched.isEmpty ? nil : DiaryDay(key: day.key, entries: matched)
        }
    }
}

/// 拍照/导入后、保存前的草稿
struct EntryDraft: Identifiable {
    let id = UUID()
    var image: UIImage
    var takenAt: Date
    var location: CLLocation?
    var locationName: String?
}

/// 回顾页统计：标签墙 / 地图足迹 / 月度分组 / 洞察卡（全部纯函数，可测）
enum DiaryStats {

    /// 洞察卡数据
    struct Insight: Equatable {
        var dayCount: Int
        var entryCount: Int
        var topLocation: String?
        var topTags: [String]
    }

    /// 标签 → 次数（不含当日小结），按次数降序、同次按字典序
    static func tagCloud(days: [DiaryDay]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for day in days {
            for entry in day.entries where !entry.isDaySummary {
                for tag in entry.tags { counts[tag, default: 0] += 1 }
            }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (tag: $0.key, count: $0.value) }
    }

    /// 带坐标的普通条目（地图标注用），按天升序
    static func locatedEntries(days: [DiaryDay]) -> [(dayKey: String, entry: DiaryEntry)] {
        days.sorted { $0.key < $1.key }.flatMap { day in
            day.entries
                .filter { !$0.isDaySummary && $0.latitude != nil && $0.longitude != nil }
                .map { (dayKey: day.key, entry: $0) }
        }
    }

    /// 按月分组：("yyyy-MM", 天数, 条目数)，按月份降序（最近在前）
    static func monthlyGroups(days: [DiaryDay]) -> [(month: String, dayCount: Int, entryCount: Int)] {
        var byMonth: [String: (days: Set<String>, entries: Int)] = [:]
        for day in days {
            let month = String(day.key.prefix(7)) // yyyy-MM-dd → yyyy-MM
            var group = byMonth[month] ?? (days: [], entries: 0)
            group.days.insert(day.key)
            group.entries += day.entries.filter { !$0.isDaySummary }.count
            byMonth[month] = group
        }
        return byMonth
            .sorted { $0.key > $1.key }
            .map { (month: $0.key, dayCount: $0.value.days.count, entryCount: $0.value.entries) }
    }

    /// 洞察卡：N 天 M 条 · 最常去 X · 高频标签 Top 3
    static func insight(days: [DiaryDay]) -> Insight {
        var locationCounts: [String: Int] = [:]
        var entryCount = 0
        for day in days {
            for entry in day.entries where !entry.isDaySummary {
                entryCount += 1
                if let location = entry.locationName, !location.isEmpty {
                    locationCounts[location, default: 0] += 1
                }
            }
        }
        let topLocation = locationCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
        return Insight(
            dayCount: days.count,
            entryCount: entryCount,
            topLocation: topLocation,
            topTags: tagCloud(days: days).prefix(3).map(\.tag)
        )
    }
}
