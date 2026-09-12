import SwiftUI

@main
struct SnapBoothApp: App {
    @StateObject private var camera = CameraService()
    @StateObject private var printer = PrinterService()

    var body: some Scene {
        WindowGroup {
            MacBoothView(camera: camera, printer: printer)
                .preferredColorScheme(.light)
        }
    }
}
