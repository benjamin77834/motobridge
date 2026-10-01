import SwiftUI

/// App del Apple Watch: muestra el botón de push-to-talk (WatchPTTView).
/// El audio pasa por el iPhone; el Watch solo envía el comando de hablar.
@main
struct MotoBridgeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchPTTView()
        }
    }
}
