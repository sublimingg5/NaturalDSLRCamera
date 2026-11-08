import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Parámetros inmutables capturados al momento del disparo para procesar el Bayer RAW en background
struct RAWDevelopmentRecipe {
    let lensCorrectionEnabled: Bool
    let luminanceNoiseReduction: Float
    let colorNoiseReduction: Float
    let filmicStrength: Float
    let appliedHighlightProtectionEV: Float
    let lookProfile: NaturalLookProfile
    let outputFormat: ProcessedImageFormat
}

struct DevelopedPhotoResult {
    let encodedData: Data
    let previewImage: UIImage
    let format: ProcessedImageFormat
}

/// Motor de revelado en GPU (Metal) que convierte el Bayer RAW de 14 bits del iPhone 11
/// en una fotografía de aspecto óptico DSLR con grano orgánico y sin procesado de IA.
final class NaturalRAWProcessor {
    static let shared = NaturalRAWProcessor()

    private let colorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }()

    /// CIContext respaldado por Metal en GPU con precisión en punto flotante de 16 bits (half-float)
    private lazy var ciContext: CIContext = {
        CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBAh,
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    private init() {}

    /// Revela los bytes de un archivo DNG (Bayer RAW) en memoria evitando el decodificador estándar de iOS
    func developBayerRAW(dngData: Data, recipe: RAWDevelopmentRecipe) -> DevelopedPhotoResult? {
        guard let rawFilter = CIRAWFilter(imageData: dngData, identifierHint: "com.adobe.raw-image") else {
            return nil
        }

        // 1. Desactivar el procesado artificial (Zero-ISP)
        if rawFilter.isLuminanceNoiseReductionSupported {
            // 0.0 conserva el 100% del grano fotónico/monocromático del sensor Sony IMX503
            rawFilter.luminanceNoiseReductionAmount = min(max(recipe.luminanceNoiseReduction, 0.0), 1.0)
        }

        if rawFilter.isColorNoiseReductionSupported {
            // Limpia únicamente el moteado RGB del interpolado Bayer sin lavar la textura
            rawFilter.colorNoiseReductionAmount = min(max(recipe.colorNoiseReduction, 0.0), 1.0)
        }

        if rawFilter.isSharpnessSupported {
            rawFilter.sharpnessAmount = 0.0 // Cero halos blancos de unsharp mask
        }

        if rawFilter.isContrastSupported {
            rawFilter.contrastAmount = 0.0
        }

        if rawFilter.isDetailSupported {
            rawFilter.detailAmount = 0.0
        }

        if rawFilter.isLocalToneMapSupported {
            // Cero levantamiento artificial de sombras (desactiva el look Smart HDR)
            rawFilter.localToneMapAmount = 0.0
        }

        // 2. Corrección óptica de lente (Activada por defecto, configurable en Settings)
        if rawFilter.isLensCorrectionSupported {
            rawFilter.isLensCorrectionEnabled = recipe.lensCorrectionEnabled
        }

        // 3. Compensación lineal si el sensor subexpuso para proteger altas luces
        if recipe.appliedHighlightProtectionEV < 0 {
            let recoveryEV = abs(recipe.appliedHighlightProtectionEV) * 0.65
            rawFilter.exposure = recoveryEV
        } else {
            rawFilter.exposure = 0.0
        }

        // 4. Ajustar la curva global base según el perfil elegido
        switch recipe.lookProfile {
        case .naturalDSLR:
            rawFilter.boostAmount = 0.84
            rawFilter.boostShadowAmount = 0.0
        case .filmicSoft:
            rawFilter.boostAmount = 0.68
            rawFilter.boostShadowAmount = 0.08
        case .monochromeGrain:
            rawFilter.boostAmount = 0.88
            rawFilter.boostShadowAmount = 0.0
        }

        guard var currentImage = rawFilter.outputImage else {
            return nil
        }

        // 5. Aplicar curva tonal en S estilo cámara con roll-off progresivo en altas luces
        currentImage = applyFilmicToneCurve(
            to: currentImage,
            strength: recipe.filmicStrength,
            profile: recipe.lookProfile
        )

        // 6. Si el usuario eligió perfil monocromático, mezclar canales emulando filtro óptico amarillo/verde
        if recipe.lookProfile == .monochromeGrain {
            currentImage = applyOpticalMonochromeMix(to: currentImage)
        }

        // 7. Exportar desde GPU a JPEG o HEIC en espacio Display P3
        let encodedData: Data?
        switch recipe.outputFormat {
        case .jpeg:
            encodedData = ciContext.jpegRepresentation(
                of: currentImage,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
            )
        case .heic:
            encodedData = ciContext.heifRepresentation(
                of: currentImage,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
            )
        }

        guard let finalData = encodedData,
              let preview = UIImage(data: finalData) else {
            return nil
        }

        return DevelopedPhotoResult(
            encodedData: finalData,
            previewImage: preview,
            format: recipe.outputFormat
        )
    }

    /// Aplica una curva de 5 puntos con caída de sombras orgánica y hombro suave en altas luces (Highlight Roll-Off)
    private func applyFilmicToneCurve(
        to image: CIImage,
        strength: Float,
        profile: NaturalLookProfile
    ) -> CIImage {
        let clampedStrength = CGFloat(min(max(strength, 0.0), 1.0))
        guard clampedStrength > 0.01 else { return image }

        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image

        // Puntos lineales de referencia: (0,0), (0.25,0.25), (0.5,0.5), (0.75,0.75), (1,1)
        let shadowToeOffset: CGFloat
        let shoulderRollOffOffset: CGFloat

        switch profile {
        case .naturalDSLR:
            shadowToeOffset = -0.022 * clampedStrength
            shoulderRollOffOffset = 0.025 * clampedStrength
        case .filmicSoft:
            shadowToeOffset = -0.010 * clampedStrength
            shoulderRollOffOffset = 0.012 * clampedStrength
        case .monochromeGrain:
            shadowToeOffset = -0.030 * clampedStrength
            shoulderRollOffOffset = 0.028 * clampedStrength
        }

        toneCurve.point0 = CGPoint(x: 0.00, y: 0.00)
        toneCurve.point1 = CGPoint(x: 0.25, y: max(0.0, 0.25 + shadowToeOffset))
        toneCurve.point2 = CGPoint(x: 0.50, y: 0.50)
        // Hombro progresivo: levanta medios-altos suavemente pero comprime el 15% final hacia 0.985 para evitar corte brusco
        toneCurve.point3 = CGPoint(x: 0.75, y: min(1.0, 0.75 + shoulderRollOffOffset))
        toneCurve.point4 = CGPoint(x: 1.00, y: 1.00 - (0.012 * clampedStrength))

        return toneCurve.outputImage ?? image
    }

    /// Conversión monocromática con pesos pancromáticos (conserva grano natural de luminancia del sensor)
    private func applyOpticalMonochromeMix(to image: CIImage) -> CIImage {
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = image
        // Pesos inspirados en película pancromática Tri-X (30% R, 59% G, 11% B)
        let rWeight: CGFloat = 0.30
        let gWeight: CGFloat = 0.59
        let bWeight: CGFloat = 0.11
        colorMatrix.rVector = CIVector(x: rWeight, y: gWeight, z: bWeight, w: 0)
        colorMatrix.gVector = CIVector(x: rWeight, y: gWeight, z: bWeight, w: 0)
        colorMatrix.bVector = CIVector(x: rWeight, y: gWeight, z: bWeight, w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return colorMatrix.outputImage ?? image
    }
}
