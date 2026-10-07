import Foundation
import CoreLocation

/// 反地理编码：把坐标转成可读的地点名称
enum Geocoder {
    static func placeName(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        // 例：上海市 · 静安区 · 静安公园
        var parts: [String] = []
        let candidates: [String?] = [
            placemark.locality,
            placemark.subLocality,
            placemark.areasOfInterest?.first ?? placemark.name,
        ]
        for candidate in candidates {
            if let value = candidate, !value.isEmpty, !parts.contains(value) {
                parts.append(value)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 拍照时获取一次当前位置
@MainActor
final class LocationService: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 请求当前位置；未授权或超时返回 nil，绝不抛错（位置对日记是加分项而非必需）
    func requestCurrentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let status = manager.authorizationStatus
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else {
                finish(with: nil)
                return
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(with: nil)
            }
        }
    }

    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: location)
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            finish(with: locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            finish(with: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else if status == .denied || status == .restricted {
                finish(with: nil)
            }
        }
    }
}
