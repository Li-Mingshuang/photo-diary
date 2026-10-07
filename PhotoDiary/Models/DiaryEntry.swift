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

/// 拍照/导入后、保存前的草稿
struct EntryDraft: Identifiable {
    let id = UUID()
    var image: UIImage
    var takenAt: Date
    var location: CLLocation?
    var locationName: String?
}
