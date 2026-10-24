import Foundation

/// Modo de transporte del bridge de audio.
enum TransportMode: String, CaseIterable, Identifiable {
    /// MultipeerConnectivity: solo entre dispositivos Apple (iPhone ↔ iPhone/iPad).
    /// Crea su propia red P2P automáticamente, sin configuración.
    case apple = "Apple (Multipeer)"
    /// Red local UDP + Bonjour: multiplataforma (iPhone ↔ Android).
    /// Requiere que ambos estén en la misma red WiFi/hotspot.
    case universal = "Universal (Android)"
    /// Auto: corre Apple (Multipeer) y Universal (WiFi) A LA VEZ. Conecta con
    /// cualquiera —iPhone por el canal que funcione, Android por WiFi— sin tener
    /// que elegir. Es el modo recomendado por defecto.
    case gateway = "Auto (todos)"

    var id: String { rawValue }

    /// Nombre corto para botones (la GUI con 3 modos no cabe con el nombre largo).
    var shortName: String {
        switch self {
        case .apple: return "Apple"
        case .universal: return "Android"
        case .gateway: return "Auto"
        }
    }

    var explanation: String {
        switch self {
        case .apple:
            return "Solo entre dispositivos Apple (WiFi directo/Bluetooth). Úsalo si quieres forzar este canal."
        case .universal:
            return "Solo por red local (iPhone↔Android o iPhone↔iPhone). Todos en la misma WiFi/hotspot."
        case .gateway:
            return "Recomendado. Conecta con cualquiera a la vez: iPhones por el mejor canal y Android por WiFi. Todos en la misma WiFi/hotspot para incluir Android."
        }
    }
}

/// Estado de conexión del transporte (común a ambos modos).
enum TransportState: String {
    case notConnected = "Sin conexión"
    case connecting = "Conectando"
    case connected = "Conectado"
}

/// Información de un peer descubierto/conectado (agnóstica del transporte).
struct TransportPeer: Identifiable, Hashable {
    let id: String     // identificador único (displayName o endpoint)
    let name: String
}

/// Abstracción común de transporte de audio. Permite intercambiar
/// MultipeerConnectivity (Apple) por red local UDP+Bonjour (universal/Android)
/// sin tocar el audio ni el controlador.
protocol AudioTransport: AnyObject {
    var mode: TransportMode { get }

    /// Callbacks. El transporte los invoca; el controlador los implementa.
    var onStateChange: ((TransportState) -> Void)? { get set }
    var onPeersChange: ((_ discovered: [TransportPeer], _ connected: [TransportPeer]) -> Void)? { get set }
    var onAudioData: ((Data) -> Void)? { get set }
    var onEvent: ((String) -> Void)? { get set }

    /// Nombre de este dispositivo (para diagnóstico).
    var localName: String { get }

    func start()
    func stop()
    /// Envía un bloque de audio (formato de red neutral: PCM Int16 mono 8 kHz).
    func sendAudio(_ data: Data)
}
