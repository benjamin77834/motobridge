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

@available(iOS 16.0, *)
struct EmergencyIntent: AppIntent {
    static var title: LocalizedStringResource = "Enviar emergencia"
    static var description = IntentDescription("Envía una alarma de emergencia a todo el grupo.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.sendAlarm()
        return .result(dialog: "Emergencia enviada al grupo")
    }
}

@available(iOS 16.0, *)
struct OutputHeadsetIntent: AppIntent {
    static var title: LocalizedStringResource = "Escuchar por los cascos"
    static var description = IntentDescription("Envía el audio del intercom a los cascos.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.setOutput(.headset)
        return .result(dialog: "Audio en los cascos")
    }
}

@available(iOS 16.0, *)
struct OutputSpeakersIntent: AppIntent {
    static var title: LocalizedStringResource = "Escuchar por las bocinas"
    static var description = IntentDescription("Envía el audio a las bocinas de la moto (CarPlay).")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.setOutput(.speakers)
        return .result(dialog: "Audio en las bocinas")
    }
}

@available(iOS 16.0, *)
struct ToggleMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Música play o pausa"
    static var description = IntentDescription("Reproduce o pausa la música (Spotify/Apple Music).")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.toggleMusic()
        return .result(dialog: "Música")
    }
}

@available(iOS 16.0, *)
struct BackToGroupIntent: AppIntent {
    static var title: LocalizedStringResource = "Volver al grupo"
    static var description = IntentDescription("Sale del canal privado o subgrupo y vuelve al grupo.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NetworkBridgeController.shared.backToGroup()
        return .result(dialog: "De vuelta al grupo")
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
            intent: EmergencyIntent(),
            phrases: [
                "Envía una emergencia en \(.applicationName)",
                "Emergencia en \(.applicationName)",
                "Pide ayuda en \(.applicationName)"
            ],
            shortTitle: "Emergencia",
            systemImageName: "exclamationmark.triangle.fill"
        )
        AppShortcut(
            intent: OutputHeadsetIntent(),
            phrases: [
                "Escucha por los cascos en \(.applicationName)",
                "Cambia a cascos en \(.applicationName)"
            ],
            shortTitle: "Escuchar por cascos",
            systemImageName: "headphones"
        )
        AppShortcut(
            intent: OutputSpeakersIntent(),
            phrases: [
                "Escucha por las bocinas en \(.applicationName)",
                "Cambia a bocinas en \(.applicationName)"
            ],
            shortTitle: "Escuchar por bocinas",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: ToggleMusicIntent(),
            phrases: [
                "Pon música en \(.applicationName)",
                "Pausa la música en \(.applicationName)"
            ],
            shortTitle: "Música play/pausa",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: BackToGroupIntent(),
            phrases: [
                "Vuelve al grupo en \(.applicationName)",
                "Regresa al grupo en \(.applicationName)"
            ],
            shortTitle: "Volver al grupo",
            systemImageName: "person.3.fill"
        )
    }
}
