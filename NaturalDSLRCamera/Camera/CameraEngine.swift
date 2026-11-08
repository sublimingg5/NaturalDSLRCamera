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

final class CameraEngine: NSObject, ObservableObject {
    // MARK: - Sesión AVFoundation
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.facu.camera.sessionQueue", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.facu.camera.rawProcessingQueue", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDevice: AVCaptureDevice?
    private var bayerRawFormat: OSType = 0
    private var kvoObservations: [NSKeyValueObservation] = []
    private var activePhotoProcessors: [Int64: PhotoCaptureDelegateProxy] = [:]

    // MARK: - Estado publicado para la UI
    @Published var isAuthorized: Bool = false
    @Published var isSessionRunning: Bool = false
    @Published var isBayerRAWSupported: Bool = false
    @Published var sensorDescription: String = "26mm ƒ/1.8 Wide"
    @Published var statusMessage: String?

    /// false = Modo Point & Shoot (Auto con protección de altas luces); true = Modo Manual DSLR
    @Published var isManualMode: Bool = false
    @Published var isCapturing: Bool = false
    @Published var isDevelopingRAW: Bool = false
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
    /// Compensación EV manual adicional en modo Point & Shoot
    @Published var userEVBias: Float = 0.0
    /// Valores seleccionados en modo Manual
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
            self.session.sessionPreset = .photo

            // En el iPhone 11 seleccionamos explícitamente el lente físico Wide 26mm f/1.8 (Sony IMX503 con OIS).
            // Evitamos cámaras virtuales (.builtInDualWideCamera) porque bloquean Bayer RAW y el control manual puro.
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

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }

                self.photoOutput.isHighResolutionCaptureEnabled = true

                if #available(iOS 14.3, *) {
                    // Desactivar Apple ProRAW en modelos Pro para garantizar lectura Bayer de 1 sola exposición
                    if self.photoOutput.isAppleProRAWSupported {
                        self.photoOutput.isAppleProRAWEnabled = false
                    }
                }

                // Buscar el formato Bayer RAW de 14 bits (kCVPixelFormatType_14Bayer_RGGB)
                if let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
                    AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
                }) {
                    self.bayerRawFormat = rawFormat
                } else if let fallbackRaw = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    self.bayerRawFormat = fallbackRaw
                }

                self.session.commitConfiguration()

                // Configurar límites y observadores del sensor
                let minISO = device.activeFormat.minISO
                let maxISO = min(device.activeFormat.maxISO, 3200)
                let rawAvailable = self.bayerRawFormat != 0

                DispatchQueue.main.async {
                    self.minISO = minISO
                    self.maxISO = maxISO
                    self.isBayerRAWSupported = rawAvailable
                    self.sensorDescription = rawAvailable
                        ? "26mm ƒ/1.8 • Bayer RAW 14-bit"
                        : "26mm ƒ/1.8 • Single Frame"
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

    // MARK: - Observación de Telemetría en Tiempo Real (KVO)
    private func observeDeviceTelemetry(_ device: AVCaptureDevice) {
        kvoObservations.removeAll()

        let isoObs = device.observe(\.iso, options: [.initial, .new]) { [weak self] dev, _ in
            let isoVal = dev.iso
            DispatchQueue.main.async {
                self?.liveISO = isoVal
            }
        }

        let durationObs = device.observe(\.exposureDuration, options: [.initial, .new]) { [weak self] dev, _ in
            let seconds = CMTimeGetSeconds(dev.exposureDuration)
            let formatted = Self.formatShutterSpeed(seconds: seconds)
            DispatchQueue.main.async {
                self?.liveShutterFormatted = formatted
            }
        }

        let lensObs = device.observe(\.lensPosition, options: [.initial, .new]) { [weak self] dev, _ in
            let pos = dev.lensPosition
            DispatchQueue.main.async {
                self?.liveLensPosition = pos
            }
        }

        let wbObs = device.observe(\.deviceWhiteBalanceGains, options: [.initial, .new]) { [weak self] dev, _ in
            let gains = dev.deviceWhiteBalanceGains
            let tempAndTint = dev.temperatureAndTintValues(for: gains)
            DispatchQueue.main.async {
                self?.liveKelvin = tempAndTint.temperature
            }
        }

        kvoObservations = [isoObs, durationObs, lensObs, wbObs]
    }

    static func formatShutterSpeed(seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "1/125" }
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        }
        let denominator = Int(round(1.0 / seconds))
        return "1/\(max(1, denominator))"
    }

    // MARK: - Alternancia entre Modo Point & Shoot y Modo Manual DSLR
    func toggleCameraMode() {
        let enteringManual = !isManualMode
        if enteringManual {
            // Copiar los valores actuales medidos por el sensor para que no haya salto brusco
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

    /// Configura el modo Point & Shoot con enfoque continuo y subexposición protectora de altas luces
    func applyPointAndShootConfiguration() {
        let protectionBias = Float(settings?.highlightProtectionBiasEV ?? -0.4)
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
        if !isManualMode {
            applyPointAndShootConfiguration()
        }
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

    // MARK: - Enfoque y Exposición al Toque en el Visor
    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()

                if !self.isManualFocusActive && device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }

                if !self.isManualMode && device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }

                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Disparo Bayer RAW y Pipeline Zero-ISP
    func capturePhoto() {
        guard !isCapturing else { return }
        DispatchQueue.main.async { self.isCapturing = true }

        let currentSettings = settings
        let recipe = RAWDevelopmentRecipe(
            lensCorrectionEnabled: currentSettings?.lensCorrectionEnabled ?? true,
            luminanceNoiseReduction: Float(currentSettings?.luminanceNoiseReduction ?? 0.0),
            colorNoiseReduction: Float(currentSettings?.colorNoiseReduction ?? 0.20),
            filmicStrength: Float(currentSettings?.filmicToneCurveStrength ?? 0.85),
            appliedHighlightProtectionEV: isManualMode ? 0.0 : Float(currentSettings?.highlightProtectionBiasEV ?? -0.4),
            lookProfile: currentSettings?.lookProfile ?? .naturalDSLR,
            outputFormat: currentSettings?.processedFormat ?? .jpeg
        )
        let isRAWModeEnabled = currentSettings?.isRAWModeEnabled ?? false
        let rawBehavior = currentSettings?.rawCaptureBehavior ?? .rawPlusProcessed

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            let photoSettings: AVCapturePhotoSettings
            if self.bayerRawFormat != 0 {
                // Pedimos ÚNICAMENTE el Bayer RAW de 14 bits al sensor:
                // esto desactiva por completo Smart HDR 2 y Deep Fusion en el A13 Bionic.
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: self.bayerRawFormat)
            } else {
                photoSettings = AVCapturePhotoSettings()
            }

            photoSettings.flashMode = .off
            photoSettings.isAutoStillImageStabilizationEnabled = false

            // Priorizar disparo único instantáneo sin espera de fusión multifotograma
            if self.photoOutput.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.speed.rawValue {
                photoSettings.photoQualityPrioritization = .speed
            }

            let uniqueID = photoSettings.uniqueID
            let proxy = PhotoCaptureDelegateProxy(
                onShutterFired: {
                    DispatchQueue.main.async {
                        self.isCapturing = false
                        self.isDevelopingRAW = true
                    }
                },
                onPhotoDataReceived: { [weak self] rawOrProcessedData, isRaw in
                    guard let self = self else { return }
                    self.activePhotoProcessors.removeValue(forKey: uniqueID)
                    self.handleCapturedData(
                        data: rawOrProcessedData,
                        isBayerRAW: isRaw,
                        recipe: recipe,
                        isRAWModeEnabled: isRAWModeEnabled,
                        rawBehavior: rawBehavior
                    )
                },
                onError: { [weak self] error in
                    guard let self = self else { return }
                    self.activePhotoProcessors.removeValue(forKey: uniqueID)
                    DispatchQueue.main.async {
                        self.isCapturing = false
                        self.isDevelopingRAW = false
                        self.statusMessage = "Error de captura: \(error.localizedDescription)"
                    }
                }
            )

            self.activePhotoProcessors[uniqueID] = proxy
            self.photoOutput.capturePhoto(with: photoSettings, delegate: proxy)
        }
    }

    private func handleCapturedData(
        data: Data,
        isBayerRAW: Bool,
        recipe: RAWDevelopmentRecipe,
        isRAWModeEnabled: Bool,
        rawBehavior: RawCaptureBehavior
    ) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // Caso 1: El botón RAW está activado y el usuario eligió "Solo DNG crudo"
            if isBayerRAW && isRAWModeEnabled && rawBehavior == .rawOnly {
                self.saveToPhotoLibrary(processedData: nil, rawDNGData: data)
                DispatchQueue.main.async {
                    self.isDevelopingRAW = false
                }
                return
            }

            // Caso 2: Revelamos el Bayer RAW con nuestro pipeline Zero-ISP (CIRAWFilter en GPU)
            if isBayerRAW,
               let developed = NaturalRAWProcessor.shared.developBayerRAW(dngData: data, recipe: recipe) {
                let dngToSave: Data? = (isRAWModeEnabled && rawBehavior == .rawPlusProcessed) ? data : nil
                self.saveToPhotoLibrary(processedData: developed.encodedData, rawDNGData: dngToSave)
                DispatchQueue.main.async {
                    self.lastCapturedPreview = developed.previewImage
                    self.isDevelopingRAW = false
                }
            } else {
                // Fallback por si se corre en un dispositivo sin soporte RAW
                self.saveToPhotoLibrary(processedData: data, rawDNGData: nil)
                let fallbackPreview = UIImage(data: data)
                DispatchQueue.main.async {
                    self.lastCapturedPreview = fallbackPreview
                    self.isDevelopingRAW = false
                }
            }
        }
    }

    private func saveToPhotoLibrary(processedData: Data?, rawDNGData: Data?) {
        PHPhotoLibrary.shared().performChanges({
            if let processed = processedData {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: processed, options: nil)
            }
            if let dng = rawDNGData {
                let rawCreationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "com.adobe.raw-image"
                rawCreationRequest.addResource(with: .photo, data: dng, options: options)
            }
        }, completionHandler: { [weak self] success, error in
            if !success, let error = error {
                DispatchQueue.main.async {
                    self?.statusMessage = "Error guardando foto: \(error.localizedDescription)"
                }
            }
        })
    }
}

// MARK: - Delegate Proxy para cada captura
private final class PhotoCaptureDelegateProxy: NSObject, AVCapturePhotoCaptureDelegate {
    private let onShutterFired: () -> Void
    private let onPhotoDataReceived: (Data, Bool) -> Void
    private let onError: (Error) -> Void

    init(
        onShutterFired: @escaping () -> Void,
        onPhotoDataReceived: @escaping (Data, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onShutterFired = onShutterFired
        self.onPhotoDataReceived = onPhotoDataReceived
        self.onError = onError
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onShutterFired()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            onError(error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            onError(NSError(domain: "NaturalDSLRCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sin datos del sensor"]))
            return
        }
        onPhotoDataReceived(data, photo.isRawPhoto)
    }
}
