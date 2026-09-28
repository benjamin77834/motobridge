import AppIntents

/// Comandos de voz vía Siri (App Intents). El usuario dice "Oye Siri, <frase>".
/// Cada intent ejecuta una acción en el controller compartido.
///
/// Nota: los intents corren en el proceso de la app; usamos
/// NetworkBridgeController.shared para actuar sobre el bridge.

@available(iOS 16.0, *)
struct StartBridgeIntent: AppIntent {
    static var title: LocalizedStringResource = "Activar bridge"
    static var description = IntentDescription("Inicia el puente de audio de MotoBridge.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.start()
        return .result(dialog: "Bridge activado")
    }
}

@available(iOS 16.0, *)
struct StopBridgeIntent: AppIntent {
    static var title: LocalizedStringResource = "Detener bridge"
    static var description = IntentDescription("Detiene el puente de audio de MotoBridge.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.stop()
        return .result(dialog: "Bridge detenido")
    }
}

@available(iOS 16.0, *)
struct MicOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Activar micrófono"
    static var description = IntentDescription("Abre el micrófono para transmitir.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.setMicOpen(true)
        return .result(dialog: "Micrófono activado")
    }
}

@available(iOS 16.0, *)
struct MicOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Silenciar micrófono"
    static var description = IntentDescription("Silencia el micrófono.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.setMicOpen(false)
        return .result(dialog: "Micrófono silenciado")
    }
}

@available(iOS 16.0, *)
struct VolumeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Subir volumen"
    static var description = IntentDescription("Sube el volumen de escucha.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.volumeUp()
        return .result(dialog: "Volumen arriba")
    }
}

@available(iOS 16.0, *)
struct VolumeDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Bajar volumen"
    static var description = IntentDescription("Baja el volumen de escucha.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.volumeDown()
        return .result(dialog: "Volumen abajo")
    }
}

/// Frases con las que Siri invoca cada acción. \(.applicationName) = MotoBridge.
@available(iOS 16.0, *)
struct MotoBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartBridgeIntent(),
            phrases: [
                "Activa el bridge en \(.applicationName)",
                "Inicia \(.applicationName)",
                "Conecta \(.applicationName)"
            ],
            shortTitle: "Activar bridge",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: StopBridgeIntent(),
            phrases: [
                "Detén el bridge en \(.applicationName)",
                "Desconecta \(.applicationName)"
            ],
            shortTitle: "Detener bridge",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: MicOnIntent(),
            phrases: [
                "Activa el micrófono en \(.applicationName)",
                "Abre el micrófono en \(.applicationName)"
            ],
            shortTitle: "Activar micrófono",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: MicOffIntent(),
            phrases: [
                "Silencia el micrófono en \(.applicationName)",
                "Silencia \(.applicationName)"
            ],
            shortTitle: "Silenciar micrófono",
            systemImageName: "mic.slash.fill"
        )
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: ["Sube el volumen en \(.applicationName)"],
            shortTitle: "Subir volumen",
            systemImageName: "speaker.plus.fill"
        )
        AppShortcut(
            intent: VolumeDownIntent(),
            phrases: ["Baja el volumen en \(.applicationName)"],
            shortTitle: "Bajar volumen",
            systemImageName: "speaker.minus.fill"
        )
    }
}
