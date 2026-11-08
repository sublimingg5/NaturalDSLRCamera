import Foundation
import SwiftUI

/// Modos de ráfaga y acumulación multi-fotograma (Google HDR+ / GCam)
enum StackBurstMode: String, CaseIterable, Identifiable {
    case quick = "QUICK_8"
    case balanced = "BALANCED_15"
    case deepStack = "DEEP_25"

    var id: String { rawValue }

    var frameCount: Int {
        switch self {
        case .quick: return 8
        case .balanced: return 15
        case .deepStack: return 25
        }
    }

    var displayName: String {
        switch self {
        case .quick: return "8 Frames (Rápido / Día)"
        case .balanced: return "15 Frames (Equilibrado)"
        case .deepStack: return "25 Frames (GCam Máxima Calidad)"
        }
    }

    var shortBadge: String {
        switch self {
        case .quick: return "HDR+ 8F"
        case .balanced: return "HDR+ 15F"
        case .deepStack: return "GCAM 25F"
        }
    }
}

/// Formato de contenedor para la foto revelada por nuestro pipeline
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

/// Perfiles de color inspirados en cámaras dedicadas
enum NaturalLookProfile: String, CaseIterable, Identifiable {
    case canonDSLR = "CANON_HTP"
    case filmicSoft = "FILMIC"
    case monochrome = "MONO"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .canonDSLR: return "Canon HTP"
        case .filmicSoft: return "Filmic Soft"
        case .monochrome: return "B&W Grain"
        }
    }

    var shortBadge: String {
        switch self {
        case .canonDSLR: return "CANON D+"
        case .filmicSoft: return "FILM"
        case .monochrome: return "B&W"
        }
    }
}

/// Configuración persistente de la cámara y del pipeline Metal
final class CameraSettings: ObservableObject {
    /// Modo de ráfaga multi-cuadro (8, 15 o 25 frames)
    @AppStorage("stackBurstMode") var stackBurstModeRaw: String = StackBurstMode.deepStack.rawValue

    /// Guardar el fotograma individual de referencia para comparar antes/después en el carrete
    @AppStorage("saveReferenceFrame") var saveReferenceFrame: Bool = true

    /// Corrección óptica de lente
    @AppStorage("lensCorrectionEnabled") var lensCorrectionEnabled: Bool = true

    /// Formato de imagen final (JPEG o HEIC)
    @AppStorage("processedImageFormat") var processedFormatRaw: String = ProcessedImageFormat.jpeg.rawValue

    /// Perfil de color
    @AppStorage("naturalLookProfile") var lookProfileRaw: String = NaturalLookProfile.canonDSLR.rawValue

    /// Subexposición intencional protectora de altas luces (Canon HTP / Google HDR+)
    @AppStorage("highlightProtectionBiasEV") var highlightProtectionBiasEV: Double = -0.7

    /// Compresión de hombro logarítmico Canon HTP (0.2 a 0.8)
    @AppStorage("shoulderCompression") var shoulderCompression: Double = 0.35

    /// Acutancia óptica de microcontraste (0.0 a 1.0)
    @AppStorage("acutanceStrength") var acutanceStrength: Double = 0.30

    /// Mostrar cuadrícula de tercios en el visor
    @AppStorage("showGridOverlay") var showGridOverlay: Bool = true

    var stackBurstMode: StackBurstMode {
        get { StackBurstMode(rawValue: stackBurstModeRaw) ?? .deepStack }
        set { stackBurstModeRaw = newValue.rawValue }
    }

    var processedFormat: ProcessedImageFormat {
        get { ProcessedImageFormat(rawValue: processedFormatRaw) ?? .jpeg }
        set { processedFormatRaw = newValue.rawValue }
    }

    var lookProfile: NaturalLookProfile {
        get { NaturalLookProfile(rawValue: lookProfileRaw) ?? .canonDSLR }
        set { lookProfileRaw = newValue.rawValue }
    }

    func resetToDSLRDefaults() {
        stackBurstMode = .deepStack
        saveReferenceFrame = true
        lensCorrectionEnabled = true
        highlightProtectionBiasEV = -0.7
        shoulderCompression = 0.35
        acutanceStrength = 0.30
        processedFormat = .jpeg
        lookProfile = .canonDSLR
    }
}
