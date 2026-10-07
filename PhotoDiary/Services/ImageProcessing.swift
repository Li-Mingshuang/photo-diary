import UIKit

extension UIImage {
    /// 修正拍摄方向并按最长边等比缩小，控制存储与上传体积
    func downscaledTo(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else {
            return normalizedOrientation()
        }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 把带方向信息的图片归一化为 .up，避免导出 JPEG 后旋转丢失
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            self.draw(at: .zero)
        }
    }
}
