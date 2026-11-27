import SwiftUI

/// App del Apple Watch: control remoto de Mono Bridge. No capta ni reproduce
/// audio; el audio sigue por el iPhone y sus audífonos.
@main
struct MotoBridgeWatchApp: App {
    @StateObject private var model = WatchRemoteModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refresh() }
                }
        }
    }
}
