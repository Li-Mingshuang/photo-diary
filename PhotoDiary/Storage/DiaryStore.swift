import Foundation
import UIKit

enum DiaryStoreError: LocalizedError {
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "图片保存失败"
        }
    }
}

/// 日记仓库：内存索引 + 磁盘 Markdown 归档
/// 目录结构：
///   diaries/
///     2026-10-07.md
///     images/IMG_20261007-143000-ab12cd34.jpg
@MainActor
final class DiaryStore: ObservableObject {
    @Published private(set) var days: [DiaryDay] = []

    let rootURL: URL
    private var entriesByDay: [String: [DiaryEntry]] = [:]

    /// - Parameter rootURL: 归档根目录，默认 Documents/diaries（测试可传临时目录）
    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.rootURL = documents.appendingPathComponent("diaries", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
    }

    var imagesURL: URL {
        rootURL.appendingPathComponent("images", isDirectory: true)
    }

    func markdownURL(forDayKey key: String) -> URL {
        rootURL.appendingPathComponent("\(key).md")
    }

func imageURL(for fileName: String) -> URL {
imagesURL.appendingPathComponent(fileName)
}

/// 语音日记音频目录（diaries/audio/）
var audioURL: URL {
    rootURL.appendingPathComponent("audio", isDirectory: true)
}

func audioFileURL(for fileName: String) -> URL {
    audioURL.appendingPathComponent(fileName)
}

// MARK: - 月度回顾文件（diaries/monthly/yyyy-MM.md，不参与按天索引）

var monthlyDirectory: URL {
    rootURL.appendingPathComponent("monthly", isDirectory: true)
}

func loadMonthlySummary(for monthKey: String) -> MonthlySummaryCodec.MonthlySummary? {
    MonthlySummaryCodec.load(from: monthlyDirectory.appendingPathComponent(MonthlySummaryCodec.fileName(forMonthKey: monthKey)))
}

func saveMonthlySummary(monthKey: String, text: String, model: String, entryCount: Int) throws {
    try FileManager.default.createDirectory(at: monthlyDirectory, withIntermediateDirectories: true)
    let markdown = MonthlySummaryCodec.render(
        monthKey: monthKey, text: text, generatedAt: Date(), model: model, entryCount: entryCount
    )
    try markdown.write(to: monthlyDirectory.appendingPathComponent(MonthlySummaryCodec.fileName(forMonthKey: monthKey)),
                       atomically: true, encoding: .utf8)
}

    // MARK: - 读取

    func load() {
        var map: [String: [DiaryEntry]] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "md" {
            let key = file.deletingPathExtension().lastPathComponent
            guard Self.isValidDayKey(key),
                  let markdown = try? String(contentsOf: file, encoding: .utf8) else { continue }
            map[key] = MarkdownDiaryCodec.parse(markdown, dayKey: key)
        }
        entriesByDay = map
        publish()
    }

    nonisolated static func isValidDayKey(_ key: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - 写入

    @discardableResult
    func addEntry(_ entry: DiaryEntry, image: UIImage?, audio: URL? = nil) throws -> DiaryEntry {
        var entry = entry
        if let image {
            entry.imageFileName = try saveImage(image, for: entry)
        }
        if let audio {
            entry.audioFileName = try saveAudio(audio, for: entry)
        }
        let key = DayKey.key(for: entry.createdAt)
        var list = entriesByDay[key] ?? []
        list.append(entry)
        list.sort { $0.createdAt < $1.createdAt }
        entriesByDay[key] = list
        try persist(dayKey: key)
        publish()
        return entry
    }

    func updateEntry(_ entry: DiaryEntry) {
        let key = DayKey.key(for: entry.createdAt)
        guard var list = entriesByDay[key],
              let index = list.firstIndex(where: { $0.id == entry.id }) else { return }
        list[index] = entry
        entriesByDay[key] = list
        try? persist(dayKey: key)
        publish()
    }

    func deleteEntry(_ entry: DiaryEntry) {
        let key = DayKey.key(for: entry.createdAt)
        guard var list = entriesByDay[key] else { return }
        list.removeAll { $0.id == entry.id }
        if list.isEmpty {
            entriesByDay.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: markdownURL(forDayKey: key))
        } else {
            entriesByDay[key] = list
            try? persist(dayKey: key)
        }
        if let fileName = entry.imageFileName {
            try? FileManager.default.removeItem(at: imageURL(for: fileName))
        }
        if let fileName = entry.audioFileName {
            try? FileManager.default.removeItem(at: audioFileURL(for: fileName))
        }
        publish()
    }

    // MARK: - 私有

    private func saveImage(_ image: UIImage, for entry: DiaryEntry) throws -> String {
        let processed = image.downscaledTo(maxDimension: 2048)
        guard let data = processed.jpegData(compressionQuality: 0.85) else {
            throw DiaryStoreError.imageEncodingFailed
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: entry.createdAt)
        let fileName = "IMG_\(timestamp)_\(entry.id.uuidString.prefix(8).lowercased()).jpg"
        try data.write(to: imageURL(for: fileName), options: .atomic)
        return fileName
    }

    /// 把录音文件拷入 audio/ 目录，返回归档文件名
    private func saveAudio(_ source: URL, for entry: DiaryEntry) throws -> String {
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: entry.createdAt)
        let fileName = "REC_\(timestamp)_\(entry.id.uuidString.prefix(8).lowercased()).m4a"
        try FileManager.default.copyItem(at: source, to: audioFileURL(for: fileName))
        return fileName
    }

    private func persist(dayKey key: String) throws {
        let markdown = MarkdownDiaryCodec.render(dayKey: key, entries: entriesByDay[key] ?? [])
        try markdown.write(to: markdownURL(forDayKey: key), atomically: true, encoding: .utf8)
    }

    private func publish() {
        days = entriesByDay
            .map { DiaryDay(key: $0.key, entries: $0.value) }
            .sorted { $0.key > $1.key }
    }
}
