import Foundation

/// Estado de conexión de un intercomunicador (sección 14).
enum ConnectionState: String, Codable {
    case disconnected = "Desconectado"
    case connecting = "Conectando"
    case connected = "Conectado"
    case unavailable = "No disponible"
}

/// Fabricantes soportados / previstos (sección 19).
enum Manufacturer: String, Codable, CaseIterable {
    case freedConn = "FreedConn"
    case hysnox = "Hysnox"
    case cardo = "Cardo"
    case sena = "Sena"
    case other = "Otro"
}

/// Capacidades que un dispositivo PUEDE exponer. Ninguna se asume disponible
/// (sección 14): son opcionales y se resuelven en tiempo de ejecución.
struct DeviceCapabilities: Codable {
    var reportsBattery: Bool = false
    var exposesBLE: Bool = false
    var supportsHFP: Bool = true      // audio de voz bidireccional (típico)
    var supportsA2DP: Bool = true     // salida estéreo (típico)
    var mfiCertified: Bool = false    // los intercoms genéricos NO lo son
}

/// Protocolo común de un intercomunicador (sección 14).
///
/// IMPORTANTE: en iOS el audio Bluetooth Classic (HFP/A2DP) lo gestiona el
/// sistema, no la app (ver FEASIBILITY_REPORT). Por eso, inicialmente estas
/// implementaciones actúan como adaptadores/identificadores: representan al
/// dispositivo y su estado observable vía AVAudioSession, no un canal de audio
/// que la app controle directamente.
protocol IntercomDevice: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var manufacturer: Manufacturer { get }
    var model: String { get }
    var connectionState: ConnectionState { get }
    var batteryLevel: Int? { get }        // nil si no se conoce
    var capabilities: DeviceCapabilities { get }

    func connect()
    func disconnect()
    func getStatus() -> ConnectionState
}
