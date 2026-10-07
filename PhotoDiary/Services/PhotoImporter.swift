import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import CoreLocation
import ImageIO

struct ImportedPhoto {
    var image: UIImage
    var takenAt: Date?
    var location: CLLocation?
}

enum PhotoImportError: LocalizedError {
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "照片读取失败，请换一张试试"
        }
    }
}

/// 从相册导入照片，并尽量恢复其拍摄时间与地点
enum PhotoImporter {
    static func load(from item: PhotosPickerItem) async throws -> ImportedPhoto {
        var takenAt: Date?
        var location: CLLocation?

        // 优先从 PHAsset 拿创建时间与位置（信息最准确）
        if let assetID = item.itemIdentifier {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            if let asset = assets.firstObject {
                takenAt = asset.creationDate
                location = asset.location
            }
        }

        guard let data = try await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            throw PhotoImportError.loadFailed
        }

        // 兜底：从 EXIF 中解析
        if takenAt == nil || location == nil {
            let exif = EXIFReader.read(from: data)
            takenAt = takenAt ?? exif.date
            location = location ?? exif.location
        }

        return ImportedPhoto(image: image, takenAt: takenAt, location: location)
    }
}

/// 用 ImageIO 解析 JPEG/HEIC 数据里的 EXIF 拍摄时间与 GPS 信息
enum EXIFReader {
    static func read(from data: Data) -> (date: Date?, location: CLLocation?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return (nil, nil)
        }

        var date: Date?
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            date = formatter.date(from: dateString)
        }

        var location: CLLocation?
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            var lat = latitude
            var lon = longitude
            if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
            location = CLLocation(latitude: lat, longitude: lon)
        }

        return (date, location)
    }
}
