import Foundation

/// Modo de transporte del bridge de audio.
enum TransportMode: String, CaseIterable, Identifiable {
    /// MultipeerConnectivity: solo entre dispositivos Apple (iPhone ↔ iPhone/iPad).
    /// Crea su propia red P2P automáticamente, sin configuración.
    case apple = "Apple (Multipeer)"
    /// Red local UDP + Bonjour: multiplataforma (iPhone ↔ Android).
    /// Requiere que ambos estén en la misma red WiFi/hotspot.
    case universal = "Universal (Android)"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .apple:
            return "Entre dispositivos Apple. Se conectan solos, sin red (WiFi directo/Bluetooth)."
        case .universal:
            return "Compatible con Android. Ambos deben estar en la misma red WiFi o hotspot."
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
