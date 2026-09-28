import SwiftUI

@main
struct MotoBridgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                // El Network Bridge es la función principal → vista de inicio.
                NetworkBridgeView()
            }
            .environmentObject(appState)
            .environmentObject(appState.audioSession)
            .environmentObject(appState.logger)
            .preferredColorScheme(.dark) // Dark Mode por defecto (sección 12)
        }
    }
}
