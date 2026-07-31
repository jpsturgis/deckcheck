import AVFoundation
import UIKit
import Combine

/// A custom AVFoundation capture session for card scanning (spec §6). Unlike the
/// system picker, this gives us a **live preview** and control of the device —
/// continuous autofocus and a macro-capable virtual device — so close-up card reads
/// are sharp in the preview (you shoot when it looks right) instead of the picker's
/// abrupt "switch to macro after a beat." It also stays open for rapid-fire capture.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.pokecatalog.camera.session")
    private var configured = false
    private var inFlight = Set<PhotoCaptureDelegate>() // retain delegates until capture completes

    @Published var authorized = false
    @Published var unavailable = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorized = granted
                    self.unavailable = !granted
                    if granted { self.run() }
                }
            }
        default:
            authorized = false
            unavailable = true
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Capture a full-resolution still; `completion` is called on the main queue.
    func capture(_ completion: @escaping (UIImage) -> Void) {
        queue.async {
            guard self.session.isRunning else { return }
            // Upright pixels so Vision reads text right-side-up.
            if let conn = self.output.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            let delegate = PhotoCaptureDelegate { image in
                if let image { DispatchQueue.main.async { completion(image) } }
            }
            delegate.onFinish = { [weak self] d in self?.queue.async { self?.inFlight.remove(d) } }
            self.inFlight.insert(delegate)
            self.output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - setup

    private func run() {
        queue.async {
            if !self.configured { self.configure(); self.configured = true }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Prefer the plain wide (main) lens. The virtual multi-cam devices auto-switch
        // to the ultra-wide *macro* lens up close — a smaller, noisier sensor that made
        // captures grainy vs. the system camera's main-lens shots. The main lens can't
        // focus quite as close, so the card frames a little farther back; the trade buys
        // its sharper, lower-noise sensor.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera,
        ]
        let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .back
        ).devices.first

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.unavailable = true }
            return
        }
        session.addInput(input)
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .quality
            // NB: do NOT force output.maxPhotoDimensions to the sensor max. On recent
            // iPhones that's 48MP; a whole scan batch of those decoded images blew past
            // memory and got the app jetsam-killed mid-batch. The .photo preset's
            // default (~12MP) is plenty for OCR + the crop, and is what worked before.
        }

        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        // Cards are held close — bias AF to the near range so it locks onto the card
        // (and doesn't hunt to infinity), for a sharper "snap" at capture.
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()

        session.commitConfiguration()
    }
}

/// One-shot photo delegate; retained by the controller until it finishes.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void
    var onFinish: ((PhotoCaptureDelegate) -> Void)?

    init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        defer { onFinish?(self) }
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }
}
