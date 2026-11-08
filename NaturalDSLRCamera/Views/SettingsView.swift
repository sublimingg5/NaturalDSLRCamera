import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: CameraSettings
    @ObservedObject var engine: CameraEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                // MARK: - 1. Modo de Ráfaga y Acumulación (Google HDR+ / GCam)
                Section(
                    header: Text("Ráfaga Multi-Cuadro (Google HDR+ / GCam)"),
                    footer: Text("En modo 25 Frames (GCam), la cámara acumula luz durante ~1.5 segundos con reducción física del 80% del ruido sin efecto acuarela.")
                ) {
                    Picker("Profundidad de ráfaga", selection: $settings.stackBurstModeRaw) {
                        ForEach(StackBurstMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }

                    Toggle("Guardar cuadro individual de referencia", isOn: $settings.saveReferenceFrame)
                }

                // MARK: - 2. Tono y Rango Dinámico Analógico (Canon HTP)
                Section(
                    header: Text("Colorimetría y Tono Analógico (Canon HTP)"),
                    footer: Text("Highlight Tone Priority comprime suavemente las altas luces para que las paredes blancas y lámparas no se quemen a blanco 255.")
                ) {
                    Picker("Formato de exportación", selection: $settings.processedFormatRaw) {
                        ForEach(ProcessedImageFormat.allCases) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Compresión de hombro Canon HTP")
                            Spacer()
                            Text("\(Int(settings.shoulderCompression * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.shoulderCompression, in: 0.15...0.70, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Acutancia óptica (Fine Detail)")
                            Spacer()
                            Text("\(Int(settings.acutanceStrength * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.acutanceStrength, in: 0.0...0.80, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Protección de altas luces en P&S")
                            Spacer()
                            Text(String(format: "%+.1f EV", settings.highlightProtectionBiasEV))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { settings.highlightProtectionBiasEV },
                                set: { newVal in
                                    settings.highlightProtectionBiasEV = newVal
                                    if !engine.isManualMode {
                                        engine.applyPointAndShootConfiguration()
                                    }
                                }
                            ),
                            in: -1.5...0.0,
                            step: 0.1
                        )
                    }
                }

                // MARK: - 3. Óptica y Visor
                Section(header: Text("Óptica y Visor")) {
                    Toggle("Corrección óptica de lente", isOn: $settings.lensCorrectionEnabled)
                    Toggle("Mostrar cuadrícula de tercios", isOn: $settings.showGridOverlay)
                }

                // MARK: - 4. Diagnóstico del Pipeline en Hardware
                Section(header: Text("Diagnóstico del Pipeline")) {
                    HStack {
                        Text("Sensor activo")
                        Spacer()
                        Text(engine.sensorDescription)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Stream de Hardware")
                        Spacer()
                        Text("YUV 420 BiPlanar Full Range")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Alineación & Fusión")
                        Spacer()
                        Text("Metal GPU • Anti-Ghosting")
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Deep Fusion & Smart HDR")
                        Spacer()
                        Text("Bypasseado (100% Off)")
                            .foregroundColor(.green)
                    }
                }

                Section {
                    Button("Restaurar valores óptimos GCam / Canon") {
                        settings.resetToDSLRDefaults()
                        if !engine.isManualMode {
                            engine.applyPointAndShootConfiguration()
                        }
                    }
                    .foregroundColor(.yellow)
                }
            }
            .navigationTitle("Ajustes de Cámara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
