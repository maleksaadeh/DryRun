import ARKit
import AVFoundation
import OSLog
import simd

/// Establishes and reports the colour-measurement footing for a session.
///
/// Auto white balance and auto exposure are the enemy of measured colour accuracy: they retune
/// per frame, so the same wall reads differently as the user pans. Locking them makes the camera
/// a repeatable instrument. Whether that lock is available at all is the single biggest open
/// question in this approach, so this type reports which path it actually obtained rather than
/// assuming success.
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

    /// Whether the settled path has been reported, so the log records it once per session
    /// rather than every frame.
    private var hasLoggedSource = false

    // Which path the illuminant came from is no longer on screen, so the log is the only
    // place it is recorded. Readable off `devicectl ... --console` when a colour looks wrong
    // and the question is whether the camera was locked.
    private static let log = Logger(subsystem: "MAS.WallPreviewer", category: "calibration")

    /// Attempts to take manual control of the capture device.
    ///
    /// - Note: `configurableCaptureDeviceForPrimaryCamera` is documented to return `nil` when the
    ///   primary camera is being used for tracking — which is exactly what world tracking does.
    ///   It is therefore expected to fail on some device and configuration combinations, and the
    ///   fallback path is not dead code.
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
                // Lock at the current auto solution: the camera has already solved for the scene
                // illuminant, and that solution is the measurement we want to read back.
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
    ///
    /// Prefers the locked device's chromaticity because it is the camera's actual solved white
    /// point. `ARLightEstimate.ambientColorTemperature` is itself derived from the camera's white
    /// balance compensation and rounded for rendering use, so it is a hint, not a measurement.
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

    /// McCamy's cubic approximation of correlated colour temperature from chromaticity.
    ///
    /// Display only — the render path uses the `xy` chromaticity directly and never round-trips
    /// through a temperature, which would discard the tint (green/magenta) axis entirely.
    private func approximateCCT(xy: SIMD2<Float>) -> Float {
        let denominator = 0.1858 - xy.y
        guard abs(denominator) > 1e-6 else { return 6500 }
        let n = (xy.x - 0.3320) / denominator
        return 449 * powf(n, 3) + 3525 * powf(n, 2) + 6823.3 * n + 5520.33
    }
}
