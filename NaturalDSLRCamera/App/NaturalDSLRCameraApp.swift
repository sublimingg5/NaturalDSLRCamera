import SwiftUI

@main
struct NaturalDSLRCameraApp: App {
    @StateObject private var settings = CameraSettings()

    var body: some Scene {
        WindowGroup {
            CameraView(settings: settings)
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
        }
    }
}
