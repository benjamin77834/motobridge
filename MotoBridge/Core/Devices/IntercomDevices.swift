import Foundation

/// Base común para los adaptadores de dispositivo. No controla el audio
/// directamente (lo hace iOS); refleja identidad y estado.
class BaseIntercomDevice: IntercomDevice, ObservableObject {
    let id: String
    let name: String
    let manufacturer: Manufacturer
    let model: String
    @Published var connectionState: ConnectionState
    @Published var batteryLevel: Int?
    let capabilities: DeviceCapabilities

    private let log = Logger.shared

    init(id: String,
         name: String,
         manufacturer: Manufacturer,
         model: String,
         capabilities: DeviceCapabilities) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.capabilities = capabilities
        self.connectionState = .disconnected
        self.batteryLevel = nil
    }

    func connect() {
        // En iOS el emparejamiento/conexión Bluetooth Classic se hace en Ajustes.
        // Aquí solo reflejamos intención y dejamos que la detección real venga
        // de AVAudioSession (ruta activa). No inventamos una conexión.
        log.info(.connection, "\(name): connect() solicitado (la conexión BT real se gestiona en Ajustes de iOS)")
        connectionState = .connecting
    }

    func disconnect() {
        log.info(.connection, "\(name): disconnect() solicitado")
        connectionState = .disconnected
    }

    func getStatus() -> ConnectionState { connectionState }

    /// Actualiza el estado a partir de si su tipo de ruta aparece activo en AVAudioSession.
    func updateFromAudioRoute(isPresentInRoute present: Bool) {
        connectionState = present ? .connected : .disconnected
    }
}

/// Adaptador para FreedConn T-COM VB.
final class FreedConnDevice: BaseIntercomDevice {
    init() {
        super.init(
            id: "freedconn-tcom-vb",
            name: "FreedConn",
            manufacturer: .freedConn,
            model: "T-COM VB",
            capabilities: DeviceCapabilities(
                reportsBattery: false,
                exposesBLE: false,
                supportsHFP: true,
                supportsA2DP: true,
                mfiCertified: false
            )
        )
    }
}

/// Adaptador para Hysnox.
final class HysnoxDevice: BaseIntercomDevice {
    init() {
        super.init(
            id: "hysnox",
            name: "Hysnox",
            manufacturer: .hysnox,
            model: "Hysnox",
            capabilities: DeviceCapabilities(
                reportsBattery: false,
                exposesBLE: false,
                supportsHFP: true,
                supportsA2DP: true,
                mfiCertified: false
            )
        )
    }
}
