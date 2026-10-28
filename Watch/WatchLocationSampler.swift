import Foundation
import CoreLocation
import WatchKit

/// Opt-in, coarse, one-shot samples. No continuous GPS session or background-location mode.
final class WatchLocationSampler: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let context: RecordingContextStore
    private var sessionID: UUID?
    private var timer: Timer?
    private var requesting = false
    var onError: ((String) -> Void)?
    init(context: RecordingContextStore) {
        self.context = context; super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1000
    }
    func start(sessionID: UUID) {
        stop(); self.sessionID = sessionID
        guard (try? context.settings().locationEnabled) == true else { self.sessionID = nil; return }
        if manager.authorizationStatus == .notDetermined {
            guard WKApplication.shared().applicationState == .active else { return }
            manager.requestWhenInUseAuthorization()
        } else { sample() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() {
        timer?.invalidate(); timer = nil; sessionID = nil; requesting = false
        manager.stopUpdatingLocation()
    }
    private func sample() {
        guard sessionID != nil, !requesting,
              (try? context.settings().locationEnabled) == true else { return }
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else { return }
        let device = WKInterfaceDevice.current()
        let charging = device.batteryState == .charging || device.batteryState == .full
        guard charging || device.batteryLevel < 0 || device.batteryLevel >= 0.2 else { return }
        requesting = true; manager.requestLocation()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            onError?("未获得位置权限，录音仍会继续。")
        } else { sample() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        requesting = false
        guard let sessionID = sessionID, (try? context.settings().locationEnabled) == true,
              let value = locations.last, value.horizontalAccuracy >= 0,
              value.horizontalAccuracy <= 10_000, abs(value.timestamp.timeIntervalSinceNow) < 120 else { return }
        // Store an approximate area, rather than retaining a precise point supplied by the OS.
        let coordinate = RecordedCoordinate(latitude: (value.coordinate.latitude * 100).rounded() / 100,
                                            longitude: (value.coordinate.longitude * 100).rounded() / 100,
                                            horizontalAccuracy: max(1000, value.horizontalAccuracy))
        do { try context.addLocation(sessionID: sessionID, at: value.timestamp, coordinate: coordinate) }
        catch { onError?("位置未保存，录音仍会继续。") }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requesting = false
        // A missed context sample must never stop audio capture or manufacture a location.
    }
    deinit { timer?.invalidate() }
}
