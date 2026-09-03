import ARKit
import AVFoundation
import OSLog
import simd

/// Establishes and reports the colour-measurement footing for a session.
///
/// Auto white balance and exposure retune per frame; locking them makes the camera repeatable.
@MainActor
final class CaptureCalibration: ObservableObject {

    /// How the scene illuminant is being estimated, in descending order of trustworthiness.
    enum Source: Equatable {
        /// Capture device locked; illuminant read from the camera's own white-balance solution.
        case lockedDevice(kelvin: Float)
        /// Capture device unavailable; falling back to ARKit's coarse ambient estimate.
        case arKitLightEstimate(kelvin: Float)
        /// Nothing available yet.
        case none

        var label: String {
            switch self {
            case .lockedDevice(let k):       String(format: "Locked · %.0fK", k)
            case .arKitLightEstimate(let k): String(format: "ARKit est · %.0fK", k)
            case .none:                      "Uncalibrated"
            }
        }

        /// Whether this source is good enough to make an accuracy claim against a physical sample.
        var isMeasurementGrade: Bool {
            if case .lockedDevice = self { return true }
            return false
        }
    }

    @Published private(set) var source: Source = .none
    @Published private(set) var illuminant = ColorScience.d65

    private var device: AVCaptureDevice?

    /// Whether the settled path has been logged, so it is recorded once per session.
    private var hasLoggedSource = false

    private static let log = Logger(subsystem: "com.MAS.dryrunpaint", category: "calibration")

    /// Attempts to take manual control of the capture device.
    ///
    /// - Note: `configurableCaptureDeviceForPrimaryCamera` returns `nil` while the primary camera
    ///   is used for tracking, so the fallback path is not dead code.
    func begin() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            Self.log.notice("CALIBRATION device=nil reason=notConfigurableUnderWorldTracking")
            source = .none
            return
        }
        self.device = device

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            let wb = device.isWhiteBalanceModeSupported(.locked)
            let ae = device.isExposureModeSupported(.locked)
            Self.log.notice("CALIBRATION device=configurable whiteBalanceLock=\(wb, privacy: .public) exposureLock=\(ae, privacy: .public)")
        } catch {
            Self.log.error("CALIBRATION lockFailed=\(error.localizedDescription, privacy: .public)")
            self.device = nil
        }
    }

    /// Refreshes the illuminant estimate for the current frame.
    func update(with frame: ARFrame) {
        if let device, device.whiteBalanceMode == .locked {
            let gains = device.deviceWhiteBalanceGains
            let chromaticity = device.chromaticityValues(for: gains)
            let xy = SIMD2<Float>(chromaticity.x, chromaticity.y)
            illuminant = ColorScience.whitePoint(xy: xy)
            source = .lockedDevice(kelvin: approximateCCT(xy: xy))
            logSourceOnce()
            return
        }

        guard let estimate = frame.lightEstimate else { return }
        let kelvin = Float(estimate.ambientColorTemperature)
        illuminant = ColorScience.whitePoint(kelvin: kelvin)
        source = .arKitLightEstimate(kelvin: kelvin)
        logSourceOnce()
    }

    /// Emits the settled calibration path exactly once per session.
    private func logSourceOnce() {
        guard !hasLoggedSource else { return }
        hasLoggedSource = true
        let label = source.label
        let grade = source.isMeasurementGrade
        Self.log.notice("CALIBRATION settled source=\(label, privacy: .public) measurementGrade=\(grade, privacy: .public)")
    }

    /// McCamy's cubic approximation of correlated colour temperature. Display only.
    private func approximateCCT(xy: SIMD2<Float>) -> Float {
        let denominator = 0.1858 - xy.y
        guard abs(denominator) > 1e-6 else { return 6500 }
        let n = (xy.x - 0.3320) / denominator
        return 449 * powf(n, 3) + 3525 * powf(n, 2) + 6823.3 * n + 5520.33
    }
}
