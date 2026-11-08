import SwiftUI
import UIKit

enum ManualDialTab: String, CaseIterable, Identifiable {
    case shutter = "SHUTTER"
    case iso = "ISO"
    case focus = "FOCUS"
    case wb = "WB"

    var id: String { rawValue }
}

struct CameraView: View {
    @ObservedObject var settings: CameraSettings
    @StateObject private var engine = CameraEngine()

    @State private var selectedManualTab: ManualDialTab = .shutter
    @State private var showSettingsSheet: Bool = false
    @State private var showPhotoInspector: Bool = false
    @State private var focusIndicatorPoint: CGPoint?
    @State private var showShutterFlash: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 8) {
                // MARK: - 1. Barra Superior (Modo P&S/Manual, Selector de Ráfaga GCam y Settings)
                topControlBar

                // MARK: - 2. Barra de Telemetría Óptica en Vivo
                liveTelemetryStrip

                // MARK: - 3. Visor 4:3 (Relación nativa 4032x3024 del sensor del iPhone 11)
                viewfinderContainer

                // MARK: - 4. Panel de Controles Dinámico (Point & Shoot vs Manual DSLR)
                if engine.isManualMode {
                    manualDSLRControlsPanel
                } else {
                    pointAndShootControlsPanel
                }

                // MARK: - 5. Barra Inferior de Disparo y Vista Previa
                shutterBottomBar
            }
            .padding(.vertical, 6)
        }
        .onAppear {
            engine.bind(settings: settings)
            engine.checkPermissionsAndSetup()
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(settings: settings, engine: engine)
        }
        .sheet(isPresented: $showPhotoInspector) {
            if let image = engine.lastCapturedPreview {
                CapturedPhotoInspectorView(image: image)
            }
        }
    }

    // MARK: - Barra Superior
    private var topControlBar: some View {
        HStack(spacing: 10) {
            // Botón de Modo: Point & Shoot vs Manual
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeInOut(duration: 0.18)) {
                    engine.toggleCameraMode()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: engine.isManualMode ? "dial.medium.fill" : "viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                    Text(engine.isManualMode ? "MANUAL" : "P&S AUTO")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(engine.isManualMode ? Color.yellow : Color.white.opacity(0.14))
                .foregroundColor(engine.isManualMode ? .black : .white)
                .clipShape(Capsule())
            }

            // Selector Rápido de Ráfaga (8f / 15f / 25f GCam)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                cycleBurstMode()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(settings.stackBurstMode == .deepStack ? Color.yellow : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(settings.stackBurstMode.shortBadge)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14))
                .foregroundColor(.white)
                .clipShape(Capsule())
            }

            Spacer()

            // Indicador de modo Canon HTP
            Text(settings.lookProfile.shortBadge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.yellow.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Botón de Settings
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
    }

    private func cycleBurstMode() {
        switch settings.stackBurstMode {
        case .quick: settings.stackBurstMode = .balanced
        case .balanced: settings.stackBurstMode = .deepStack
        case .deepStack: settings.stackBurstMode = .quick
        }
    }

    // MARK: - Telemetría estilo Visor DSLR
    private var liveTelemetryStrip: some View {
        HStack(spacing: 12) {
            Text("26mm ƒ/1.8")
                .foregroundColor(.gray)

            Text("\(engine.liveShutterFormatted)s")
                .foregroundColor(engine.isManualMode ? .yellow : .white)

            Text("ISO \(Int(round(engine.liveISO)))")
                .foregroundColor(engine.isManualMode ? .yellow : .white)

            Text("\(Int(round(engine.liveKelvin)))K")
                .foregroundColor(engine.isManualWhiteBalanceActive ? .yellow : .gray)

            Spacer()

            Text("METAL GPU")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 18)
    }

    // MARK: - Visor 4:3
    private var viewfinderContainer: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: engine.session) { layerPoint, devicePoint in
                    triggerFocusAnimation(at: layerPoint)
                    engine.focusAndExpose(at: devicePoint)
                }

                // Cuadrícula de Regla de los Tercios
                if settings.showGridOverlay {
                    GridOverlayShape()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
                        .allowsHitTesting(false)
                }

                // Recuadro animado de enfoque al tocar
                if let point = focusIndicatorPoint {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 68, height: 68)
                        .position(point)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                // Efecto de obturador al disparar
                if showShutterFlash {
                    Color.black
                        .opacity(0.65)
                        .allowsHitTesting(false)
                }

                // Indicador de captura / fusión
                if engine.isCapturing || engine.isDeveloping {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                                .scaleEffect(0.75)
                            Text(engine.isCapturing
                                 ? "CAPTURING \(Int(engine.captureProgress * Float(settings.stackBurstMode.frameCount)))/\(settings.stackBurstMode.frameCount)..."
                                 : "MERGING (METAL GPU)...")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.80))
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                    }
                }

                // Mensaje de estado/permisos
                if let status = engine.statusMessage {
                    Text(status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(Color.black.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .padding(.horizontal, 8)
    }

    // MARK: - Panel Point & Shoot (Compensación EV + Perfil de Color)
    private var pointAndShootControlsPanel: some View {
        VStack(spacing: 8) {
            // Selector de perfil
            HStack(spacing: 8) {
                ForEach(NaturalLookProfile.allCases) { profile in
                    let isSelected = settings.lookProfile == profile
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        settings.lookProfile = profile
                    } label: {
                        Text(profile.label)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isSelected ? Color.white : Color.white.opacity(0.10))
                            .foregroundColor(isSelected ? .black : .white.opacity(0.8))
                            .clipShape(Capsule())
                    }
                }
            }

            // Deslizador de Compensación de Exposición (EV)
            HStack(spacing: 10) {
                Text("EV")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)

                Slider(
                    value: Binding(
                        get: { engine.userEVBias },
                        set: { engine.updatePointAndShootEVBias($0) }
                    ),
                    in: -2.0...2.0,
                    step: 0.1
                )
                .accentColor(.yellow)

                Button {
                    engine.updatePointAndShootEVBias(0.0)
                } label: {
                    Text(String(format: "%+.1f", engine.userEVBias))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(abs(engine.userEVBias) > 0.05 ? .yellow : .gray)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Panel Manual DSLR (Obturador, ISO, Enfoque, Kelvin)
    private var manualDSLRControlsPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ManualDialTab.allCases) { tab in
                    let isSelected = selectedManualTab == tab
                    Button {
                        selectedManualTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(isSelected ? Color.yellow : Color.white.opacity(0.10))
                            .foregroundColor(isSelected ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.horizontal, 16)

            Group {
                switch selectedManualTab {
                case .shutter:
                    HStack(spacing: 10) {
                        Text(ShutterSpeedStep.standardSteps[engine.manualShutterStepIndex].label + "s")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 68, alignment: .leading)

                        Slider(
                            value: Binding(
                                get: { Double(engine.manualShutterStepIndex) },
                                set: { newVal in
                                    engine.manualShutterStepIndex = Int(round(newVal))
                                    engine.applyManualExposure()
                                }
                            ),
                            in: 0...Double(ShutterSpeedStep.standardSteps.count - 1),
                            step: 1
                        )
                        .accentColor(.yellow)
                    }

                case .iso:
                    HStack(spacing: 10) {
                        Text("ISO \(Int(round(engine.manualISO)))")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 82, alignment: .leading)

                        Slider(
                            value: Binding(
                                get: { engine.manualISO },
                                set: { newISO in
                                    engine.manualISO = newISO
                                    engine.applyManualExposure()
                                }
                            ),
                            in: engine.minISO...engine.maxISO,
                            step: 10
                        )
                        .accentColor(.yellow)
                    }

                case .focus:
                    HStack(spacing: 10) {
                        Button {
                            if engine.isManualFocusActive {
                                engine.setAutoFocusInManualMode()
                            } else {
                                engine.setManualFocus(engine.liveLensPosition)
                            }
                        } label: {
                            Text(engine.isManualFocusActive ? "MF" : "AF")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(engine.isManualFocusActive ? Color.yellow : Color.white.opacity(0.2))
                                .foregroundColor(engine.isManualFocusActive ? .black : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Slider(
                            value: Binding(
                                get: { engine.isManualFocusActive ? engine.manualFocusPosition : engine.liveLensPosition },
                                set: { engine.setManualFocus($0) }
                            ),
                            in: 0.0...1.0
                        )
                        .accentColor(.yellow)

                        Text(String(format: "%.2f", engine.isManualFocusActive ? engine.manualFocusPosition : engine.liveLensPosition))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 40, alignment: .trailing)
                    }

                case .wb:
                    HStack(spacing: 10) {
                        Button {
                            if engine.isManualWhiteBalanceActive {
                                engine.setAutoWhiteBalance()
                            } else {
                                engine.setManualWhiteBalance(kelvin: engine.liveKelvin)
                            }
                        } label: {
                            Text(engine.isManualWhiteBalanceActive ? "MWB" : "AWB")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(engine.isManualWhiteBalanceActive ? Color.yellow : Color.white.opacity(0.2))
                                .foregroundColor(engine.isManualWhiteBalanceActive ? .black : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Slider(
                            value: Binding(
                                get: { engine.isManualWhiteBalanceActive ? engine.manualWhiteBalanceKelvin : engine.liveKelvin },
                                set: { engine.setManualWhiteBalance(kelvin: $0) }
                            ),
                            in: 2800...8500,
                            step: 100
                        )
                        .accentColor(.yellow)

                        Text("\(Int(round(engine.isManualWhiteBalanceActive ? engine.manualWhiteBalanceKelvin : engine.liveKelvin)))K")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Barra Inferior (Miniatura + Obturador GCam con Anillo de Progreso)
    private var shutterBottomBar: some View {
        HStack {
            // Miniatura de última foto tomada
            Button {
                if engine.lastCapturedPreview != nil {
                    showPhotoInspector = true
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 52, height: 52)

                    if let preview = engine.lastCapturedPreview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                            )
                    } else {
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 70, alignment: .leading)

            Spacer()

            // Botón Obturador Estilo GCam con Anillo Concéntrico de Progreso
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                triggerShutterAnimation()
                engine.capturePhoto()
            } label: {
                ZStack {
                    // Círculo exterior base
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 4)
                        .frame(width: 76, height: 76)

                    // Anillo de progreso concéntrico animado
                    if engine.isCapturing || engine.isDeveloping {
                        Circle()
                            .trim(from: 0.0, to: CGFloat(engine.captureProgress))
                            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 76, height: 76)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.08), value: engine.captureProgress)
                    }

                    // Botón central de disparo
                    Circle()
                        .fill(Color.white)
                        .frame(width: 62, height: 62)
                        .scaleEffect((engine.isCapturing || engine.isDeveloping) ? 0.88 : 1.0)
                        .animation(.easeOut(duration: 0.1), value: engine.isCapturing)
                }
            }
            .disabled(engine.isCapturing || engine.isDeveloping)

            Spacer()

            // Información rápida de apilado y HTP
            VStack(alignment: .trailing, spacing: 2) {
                Text("STACK: \(settings.stackBurstMode.frameCount)F")
                    .foregroundColor(.yellow)
                Text("HTP: D+")
                Text("12MP")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.gray)
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    private func triggerFocusAnimation(at point: CGPoint) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            focusIndicatorPoint = point
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.2)) {
                focusIndicatorPoint = nil
            }
        }
    }

    private func triggerShutterAnimation() {
        showShutterFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            showShutterFlash = false
        }
    }
}

// MARK: - Cuadrícula de Regla de los Tercios
private struct GridOverlayShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let thirdW = rect.width / 3.0
        let thirdH = rect.height / 3.0

        for i in 1...2 {
            let x = thirdW * CGFloat(i)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = thirdH * CGFloat(i)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

// MARK: - Inspector de Foto con Zoom
private struct CapturedPhotoInspectorView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, min(value, 5.0))
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1.1 ? 1.0 : 2.5
                        }
                    }
            }
            .navigationTitle("Detalle de Foto (Doble toque 2.5x)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
