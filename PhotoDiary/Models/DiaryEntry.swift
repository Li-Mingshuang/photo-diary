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
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    /// 是否为「当日小结」（由当天多张照片合并生成，渲染在日记文件顶部）
    var isDaySummary: Bool = false

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

    var summary: String {
        entries.first?.text.components(separatedBy: .newlines).first ?? ""
    }
}

/// 日记搜索过滤（纯函数，便于测试）
enum DiarySearch {
    /// 按正文、地点、日期标题/键过滤；空查询返回全部。
    /// 命中的天仅保留命中的条目（日期本身命中则保留全部条目）。
    static func filter(_ days: [DiaryDay], query: String) -> [DiaryDay] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return days }
        return days.compactMap { day in
            if day.title.localizedCaseInsensitiveContains(q) || day.key.contains(q) {
                return day
            }
            let matched = day.entries.filter {
                $0.text.localizedCaseInsensitiveContains(q)
                    || ($0.locationName?.localizedCaseInsensitiveContains(q) ?? false)
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
