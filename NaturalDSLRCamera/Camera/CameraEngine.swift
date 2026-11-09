import AVFoundation
import Combine
import Photos
import UIKit

/// Fracciones de velocidad de obturación estándar estilo cámara dedicada
struct ShutterSpeedStep: Identifiable, Equatable {
    let label: String
    let seconds: Double
    var id: String { label }

    static let standardSteps: [ShutterSpeedStep] = [
        ShutterSpeedStep(label: "1/4", seconds: 1.0 / 4.0),
        ShutterSpeedStep(label: "1/8", seconds: 1.0 / 8.0),
        ShutterSpeedStep(label: "1/15", seconds: 1.0 / 15.0),
        ShutterSpeedStep(label: "1/30", seconds: 1.0 / 30.0),
        ShutterSpeedStep(label: "1/60", seconds: 1.0 / 60.0),
        ShutterSpeedStep(label: "1/125", seconds: 1.0 / 125.0),
        ShutterSpeedStep(label: "1/250", seconds: 1.0 / 250.0),
        ShutterSpeedStep(label: "1/500", seconds: 1.0 / 500.0),
        ShutterSpeedStep(label: "1/1000", seconds: 1.0 / 1000.0),
        ShutterSpeedStep(label: "1/2000", seconds: 1.0 / 2000.0),
        ShutterSpeedStep(label: "1/4000", seconds: 1.0 / 4000.0)
    ]
}

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: - Sesión AVFoundation
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.facu.camera.sessionQueue", qos: .userInitiated)
    private let videoDataQueue = DispatchQueue(label: "com.facu.camera.videoDataQueue", qos: .userInteractive)

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var videoDevice: AVCaptureDevice?
    private var kvoObservations: [NSKeyValueObservation] = []

    // MARK: - Estado de Ráfaga Multi-Cuadro (Google HDR+ / GCam)
    private var isCollectingBurst: Bool = false
    private var targetBurstCount: Int = 25
    private var currentBurstIndex: Int = 0

    // MARK: - Estado publicado para la UI
    @Published var isAuthorized: Bool = false
    @Published var isSessionRunning: Bool = false
    @Published var sensorDescription: String = "26mm ƒ/1.8 Wide • 12MP"
    @Published var statusMessage: String?

    /// false = Modo Point & Shoot (Auto con protección de altas luces); true = Modo Manual DSLR
    @Published var isManualMode: Bool = false
    @Published var isCapturing: Bool = false
    @Published var isDeveloping: Bool = false
    @Published var captureProgress: Float = 0.0
    @Published var lastCapturedPreview: UIImage?

    // MARK: - Telemetría óptica en tiempo real
    @Published var liveISO: Float = 64
    @Published var liveShutterFormatted: String = "1/125"
    @Published var liveLensPosition: Float = 0.5
    @Published var liveKelvin: Float = 5200

    // MARK: - Límites del hardware (iPhone 11 Sony IMX503)
    @Published var minISO: Float = 32
    @Published var maxISO: Float = 3072
    @Published var minEV: Float = -2.0
    @Published var maxEV: Float = 2.0

    // MARK: - Controles de usuario
    @Published var userEVBias: Float = 0.0
    @Published var manualISO: Float = 100
    @Published var manualShutterStepIndex: Int = 5 // 1/125 por defecto
    @Published var manualFocusPosition: Float = 0.7
    @Published var isManualFocusActive: Bool = false
    @Published var manualWhiteBalanceKelvin: Float = 5200
    @Published var isManualWhiteBalanceActive: Bool = false

    private weak var settings: CameraSettings?

    func bind(settings: CameraSettings) {
        self.settings = settings
    }

    // MARK: - Permisos e Inicialización
    func checkPermissionsAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isAuthorized = true }
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { self?.isAuthorized = granted }
                if granted { self?.setupSession() }
            }
        default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.statusMessage = "Habilitá el permiso de Cámara en Ajustes de iOS."
            }
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.session.isRunning else { return }

            self.session.beginConfiguration()
            // .photo preset configura el sensor para entregar 12MP (4032x3024) completos al stream de video
            self.session.sessionPreset = .photo

            // Seleccionar lente Wide 26mm f/1.8 (Sony IMX503 con OIS)
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusMessage = "No se encontró el sensor físico trasero."
                }
                return
            }

            self.videoDevice = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }

                // Configurar AVCaptureVideoDataOutput en YUV 420 BiPlanar Full Range
                // Esto entrega los planos Y y CbCr calibrados por hardware (AWB, BLC, Lens Shading)
                // y ELUDE al 100% el Deep Fusion y el sobreenfoque artificial de Apple.
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ]
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)

                if self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                }

                if let connection = self.videoDataOutput.connection(with: .video) {
                    connection.videoOrientation = .portrait
                    if connection.isVideoStabilizationSupported {
                        // Desactivar estabilización digital computacional que deforma bordes;
                        // confiamos exclusivamente en el OIS óptico físico.
                        connection.preferredVideoStabilizationMode = .off
                    }
                }

                self.session.commitConfiguration()

                let minISO = device.activeFormat.minISO
                let maxISO = min(device.activeFormat.maxISO, 3200)

                DispatchQueue.main.async {
                    self.minISO = minISO
                    self.maxISO = maxISO
                    self.sensorDescription = "26mm ƒ/1.8 • 12MP Hardware OIS"
                }

                self.observeDeviceTelemetry(device)
                self.applyPointAndShootConfiguration()
                self.session.startRunning()

                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusMessage = "Error iniciando sensor: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Captura de Ráfaga en Streaming)
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCollectingBurst,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if currentBurstIndex == 0 {
            // Primer frame: inicializar streaming stack en GPU
            let currentSettings = settings
            let recipe = GCamPipelineRecipe(
                exposureCompensation: Float(1.0 + abs(currentSettings?.highlightProtectionBiasEV ?? -0.7) * 0.9),
                shoulderCompression: Float(currentSettings?.shoulderCompression ?? 0.35),
                acutanceStrength: Float(currentSettings?.acutanceStrength ?? 0.30),
                readNoise: 0.012,
                shotNoise: 0.035
            )
            MetalGCamCoordinator.shared.beginStreamingStack(firstBuffer: imageBuffer, recipe: recipe)
        } else {
            // Frames subsiguientes: acumular en vuelo en GPU y liberar el CVPixelBuffer de inmediato
            MetalGCamCoordinator.shared.accumulateNextFrame(buffer: imageBuffer)
        }

        currentBurstIndex += 1
        let count = currentBurstIndex
        let target = targetBurstCount
        let progress = Float(count) / Float(target)

        DispatchQueue.main.async {
            self.captureProgress = progress
        }

        if count >= target {
            // Ráfaga completa: detener recolección y finalizar el render en Metal
            isCollectingBurst = false
            currentBurstIndex = 0

            DispatchQueue.main.async {
                self.isCapturing = false
                self.isDeveloping = true
            }

            let saveRef = settings?.saveReferenceFrame ?? true
            MetalGCamCoordinator.shared.finalizeStreamingStack { [weak self] finalImage, refImage in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.isDeveloping = false
                    self.captureProgress = 1.0
                    if let final = finalImage {
                        self.lastCapturedPreview = final
                        self.savePhotosToLibrary(finalImage: final, referenceImage: saveRef ? refImage : nil)
                    }
                }
            }
        }
    }

    // MARK: - Disparo Multi-Cuadro GCam
    func capturePhoto() {
        guard !isCapturing && !isDeveloping else { return }

        let count = settings?.stackBurstMode.frameCount ?? 25
        targetBurstCount = count
        currentBurstIndex = 0
        isCollectingBurst = true

        DispatchQueue.main.async {
            self.isCapturing = true
            self.isDeveloping = false
            self.captureProgress = 0.0
        }
    }

    private func savePhotosToLibrary(finalImage: UIImage, referenceImage: UIImage?) {
        PHPhotoLibrary.shared().performChanges({
            // 1. Guardar foto final apilada GCam / Canon HTP
            let finalRequest = PHAssetCreationRequest.forAsset()
            if let finalData = finalImage.jpegData(compressionQuality: 0.95) {
                finalRequest.addResource(with: .photo, data: finalData, options: nil)
            }

            // 2. Si el usuario activó la opción, guardar el cuadro de referencia individual para comparar
            if let ref = referenceImage,
               let refData = ref.jpegData(compressionQuality: 0.95) {
                let refRequest = PHAssetCreationRequest.forAsset()
                refRequest.addResource(with: .photo, data: refData, options: nil)
            }
        }, completionHandler: { [weak self] success, error in
            if !success, let error = error {
                DispatchQueue.main.async {
                    self?.statusMessage = "Error guardando: \(error.localizedDescription)"
                }
            }
        })
    }

    // MARK: - Telemetría en Tiempo Real (KVO)
    private func observeDeviceTelemetry(_ device: AVCaptureDevice) {
        kvoObservations.removeAll()

        let isoObs = device.observe(\.iso, options: [.initial, .new]) { [weak self] dev, _ in
            let isoVal = dev.iso
            DispatchQueue.main.async { self?.liveISO = isoVal }
        }

        let durationObs = device.observe(\.exposureDuration, options: [.initial, .new]) { [weak self] dev, _ in
            let seconds = CMTimeGetSeconds(dev.exposureDuration)
            let formatted = Self.formatShutterSpeed(seconds: seconds)
            DispatchQueue.main.async { self?.liveShutterFormatted = formatted }
        }

        let lensObs = device.observe(\.lensPosition, options: [.initial, .new]) { [weak self] dev, _ in
            let pos = dev.lensPosition
            DispatchQueue.main.async { self?.liveLensPosition = pos }
        }

        let wbObs = device.observe(\.deviceWhiteBalanceGains, options: [.initial, .new]) { [weak self] dev, _ in
            let gains = dev.deviceWhiteBalanceGains
            let tempAndTint = dev.temperatureAndTintValues(for: gains)
            DispatchQueue.main.async { self?.liveKelvin = tempAndTint.temperature }
        }

        kvoObservations = [isoObs, durationObs, lensObs, wbObs]
    }

    static func formatShutterSpeed(seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "1/125" }
        if seconds >= 1.0 { return String(format: "%.1fs", seconds) }
        let denominator = Int(round(1.0 / seconds))
        return "1/\(max(1, denominator))"
    }

    // MARK: - Alternancia entre Modo Point & Shoot y Manual DSLR
    func toggleCameraMode() {
        let enteringManual = !isManualMode
        if enteringManual {
            manualISO = min(max(liveISO, minISO), maxISO)
            manualFocusPosition = liveLensPosition
            manualWhiteBalanceKelvin = min(max(liveKelvin, 2800), 8500)
            isManualMode = true
            applyManualExposure()
        } else {
            isManualMode = false
            isManualFocusActive = false
            isManualWhiteBalanceActive = false
            applyPointAndShootConfiguration()
        }
    }

    func applyPointAndShootConfiguration() {
        let protectionBias = Float(settings?.highlightProtectionBiasEV ?? -0.7)
        let totalBias = userEVBias + protectionBias

        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }

                let clampedBias = min(max(totalBias, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clampedBias, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func updatePointAndShootEVBias(_ newBias: Float) {
        userEVBias = newBias
        if !isManualMode { applyPointAndShootConfiguration() }
    }

    // MARK: - Controles del Modo Manual DSLR
    func applyManualExposure() {
        let step = ShutterSpeedStep.standardSteps[min(max(manualShutterStepIndex, 0), ShutterSpeedStep.standardSteps.count - 1)]
        let targetISO = manualISO

        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                let minSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
                let maxSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
                let clampedSeconds = min(max(step.seconds, minSeconds), maxSeconds)
                let duration = CMTimeMakeWithSeconds(clampedSeconds, preferredTimescale: 1_000_000)
                let clampedISO = min(max(targetISO, device.activeFormat.minISO), device.activeFormat.maxISO)

                device.setExposureTargetBias(0.0, completionHandler: nil)
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setManualFocus(_ position: Float) {
        manualFocusPosition = position
        isManualFocusActive = true
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            guard device.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: min(max(position, 0.0), 1.0), completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setAutoFocusInManualMode() {
        isManualFocusActive = false
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setManualWhiteBalance(kelvin: Float) {
        manualWhiteBalanceKelvin = kelvin
        isManualWhiteBalanceActive = true
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            do {
                try device.lockForConfiguration()
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: kelvin,
                    tint: 0.0
                )
                var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1.0), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setAutoWhiteBalance() {
        isManualWhiteBalanceActive = false
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if !self.isManualFocusActive && device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if !self.isManualMode && device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }
}
