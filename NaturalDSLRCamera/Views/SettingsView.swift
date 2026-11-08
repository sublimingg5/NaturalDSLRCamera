import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: CameraSettings
    @ObservedObject var engine: CameraEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                // MARK: - 1. Óptica y Corrección de Lente
                Section(
                    header: Text("Óptica de Lente (26mm ƒ/1.8)"),
                    footer: Text("Activado por defecto. Si lo desactivás, la foto conservará el viñeteo óptico real y la geometría pura del lente de 26mm del iPhone 11.")
                ) {
                    Toggle("Corrección óptica de lente", isOn: $settings.lensCorrectionEnabled)
                    Toggle("Mostrar cuadrícula de tercios", isOn: $settings.showGridOverlay)
                }

                // MARK: - 2. Formato de Salida y Comportamiento del Botón RAW
                Section(
                    header: Text("Formatos de Guardado (JPEG / HEIC / RAW)"),
                    footer: Text("El revelado natural se exporta en espacio de color Display P3 sin pasar por el decodificador suavizado de Fotos de iOS.")
                ) {
                    Picker("Formato de foto revelada", selection: $settings.processedFormatRaw) {
                        ForEach(ProcessedImageFormat.allCases) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    }

                    Picker("Al activar el botón RAW", selection: $settings.rawCaptureBehaviorRaw) {
                        ForEach(RawCaptureBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior.rawValue)
                        }
                    }
                }

                // MARK: - 3. Ajuste Fino del Pipeline Zero-ISP (Grano y Curva Tonal)
                Section(
                    header: Text("Calibración del Revelado DSLR (CIRAWFilter)"),
                    footer: Text("Con Reducción de Ruido de Luminancia en 0%, cada variación fotónica del sensor Sony IMX503 se conserva como grano monocromático orgánico sin efecto acuarela.")
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Reducción de ruido de luminancia")
                            Spacer()
                            Text("\(Int(settings.luminanceNoiseReduction * 100))% (Grano Puro: 0%)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.luminanceNoiseReduction, in: 0.0...0.50, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Reducción de ruido de color (Bayer)")
                            Spacer()
                            Text("\(Int(settings.colorNoiseReduction * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.colorNoiseReduction, in: 0.0...0.50, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Curva Filmic S-Curve (Highlight Roll-Off)")
                            Spacer()
                            Text("\(Int(settings.filmicToneCurveStrength * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.filmicToneCurveStrength, in: 0.0...1.0, step: 0.05)
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
                            in: -1.0...0.0,
                            step: 0.1
                        )
                    }
                }

                // MARK: - 4. Estado del Sensor
                Section(header: Text("Diagnóstico del Sensor")) {
                    HStack {
                        Text("Lente activo")
                        Spacer()
                        Text(engine.sensorDescription)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Captura Bayer RAW 14-bit")
                        Spacer()
                        Text(engine.isBayerRAWSupported ? "Activa (Zero Smart HDR / Deep Fusion)" : "No soportada en este lente")
                            .foregroundColor(engine.isBayerRAWSupported ? .green : .orange)
                    }
                    HStack {
                        Text("Sobreenfoque (Unsharp Mask)")
                        Spacer()
                        Text("0.0 (Desactivado)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Mapeo Tonal Local (Smart HDR)")
                        Spacer()
                        Text("0.0 (Desactivado)")
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("Restaurar valores óptimos DSLR") {
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
