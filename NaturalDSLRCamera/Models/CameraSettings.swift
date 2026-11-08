import Foundation
import SwiftUI

/// Formato de contenedor para la foto revelada por nuestro pipeline Zero-ISP
enum ProcessedImageFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG (95% Display P3)"
        case .heic: return "HEIC (10-bit Display P3)"
        }
    }
}

/// Qué se guarda cuando el botón RAW del visor está activado
enum RawCaptureBehavior: String, CaseIterable, Identifiable {
    case rawPlusProcessed = "RAW+JPG"
    case rawOnly = "RAW_ONLY"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rawPlusProcessed: return "DNG + Foto Revelada Natural"
        case .rawOnly: return "Solo archivo DNG crudo (sin revelar)"
        }
    }
}

/// Perfiles de curva y color inspirados en cámaras dedicadas (sin alterar el grano real)
enum NaturalLookProfile: String, CaseIterable, Identifiable {
    case naturalDSLR = "DSLR"
    case filmicSoft = "FILMIC"
    case monochromeGrain = "MONO"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .naturalDSLR: return "Natural DSLR"
        case .filmicSoft: return "Filmic Soft"
        case .monochromeGrain: return "B&W Grain"
        }
    }

    var shortBadge: String { rawValue }
}

/// Configuración persistente de la cámara y del pipeline de revelado
final class CameraSettings: ObservableObject {
    /// Corrección geométrica y de viñeteo de la lente (Activada por defecto según lo pedido)
    @AppStorage("lensCorrectionEnabled") var lensCorrectionEnabled: Bool = true

    /// Estado del botón RAW en el visor principal (false = modo JPEG/HEIC directo; true = modo RAW)
    @AppStorage("isRAWModeEnabled") var isRAWModeEnabled: Bool = false

    /// Comportamiento cuando el modo RAW está activo
    @AppStorage("rawCaptureBehavior") var rawCaptureBehaviorRaw: String = RawCaptureBehavior.rawPlusProcessed.rawValue

    /// Formato de imagen para el revelado natural (JPEG o HEIC)
    @AppStorage("processedImageFormat") var processedFormatRaw: String = ProcessedImageFormat.jpeg.rawValue

    /// Perfil de revelado natural en modo Point & Shoot / Manual
    @AppStorage("naturalLookProfile") var lookProfileRaw: String = NaturalLookProfile.naturalDSLR.rawValue

    /// Reducción de ruido de luminancia (0.18 por defecto = grano orgánico fino sin "speckle" tosco)
    @AppStorage("luminanceNoiseReduction") var luminanceNoiseReduction: Double = 0.18

    /// Reducción de ruido cromático (0.95 por defecto = elimina por completo las manchas verdes y magentas del sensor)
    @AppStorage("colorNoiseReduction") var colorNoiseReduction: Double = 0.95

    /// Intensidad de la curva en S Filmic con roll-off en altas luces (0.0 a 1.0)
    @AppStorage("filmicToneCurveStrength") var filmicToneCurveStrength: Double = 0.85

    /// Subexposición automática protectora de altas luces en modo Point & Shoot (en EV)
    @AppStorage("highlightProtectionBiasEV") var highlightProtectionBiasEV: Double = -0.6

    /// Mostrar cuadrícula de tercios en el visor
    @AppStorage("showGridOverlay") var showGridOverlay: Bool = true

    var rawCaptureBehavior: RawCaptureBehavior {
        get { RawCaptureBehavior(rawValue: rawCaptureBehaviorRaw) ?? .rawPlusProcessed }
        set { rawCaptureBehaviorRaw = newValue.rawValue }
    }

    var processedFormat: ProcessedImageFormat {
        get { ProcessedImageFormat(rawValue: processedFormatRaw) ?? .jpeg }
        set { processedFormatRaw = newValue.rawValue }
    }

    var lookProfile: NaturalLookProfile {
        get { NaturalLookProfile(rawValue: lookProfileRaw) ?? .naturalDSLR }
        set { lookProfileRaw = newValue.rawValue }
    }

    func resetToDSLRDefaults() {
        lensCorrectionEnabled = true
        luminanceNoiseReduction = 0.18
        colorNoiseReduction = 0.95
        filmicToneCurveStrength = 0.85
        highlightProtectionBiasEV = -0.6
        processedFormat = .jpeg
        rawCaptureBehavior = .rawPlusProcessed
        lookProfile = .naturalDSLR
    }
}
