import UIKit
import ImageIO

/// 用 ImageIO 按目标像素降采样加载磁盘图片，避免全尺寸读入内存
enum Thumbnailer {
    /// - Parameters:
    ///   - url: 图片文件地址
    ///   - maxPixelSize: 最长边像素（传点数 × 屏幕 scale 后的值）
    static func image(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
