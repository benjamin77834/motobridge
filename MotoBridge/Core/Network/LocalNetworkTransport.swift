import Foundation
import Network
import UIKit

/// Transporte multiplataforma (iPhone ↔ Android) por red local usando UDP +
/// Bonjour/mDNS con Network framework.
///
/// Modelo: ambos dispositivos deben estar en la MISMA red WiFi/hotspot. Cada
/// dispositivo publica un servicio Bonjour `_motobridge._udp` y busca el del
/// otro. Al encontrarlo, abre una conexión UDP y envía datagramas de audio con
/// el protocolo neutral (ver PROTOCOL.md). Este mismo protocolo lo implementa
/// la app Android para interoperar.
final class LocalNetworkTransport: AudioTransport {

    let mode: TransportMode = .universal
    let localName: String

    var onStateChange: ((TransportState) -> Void)?
    var onPeersChange: ((_ discovered: [TransportPeer], _ connected: [TransportPeer]) -> Void)?
    var onAudioData: ((Data) -> Void)?
    var onEvent: ((String) -> Void)?

    /// Tipo de servicio Bonjour (debe coincidir con la app Android).
    static let serviceType = "_motobridge._udp"
    static let serviceDomain = "local."

    private let log = Logger.shared
    private let queue = DispatchQueue(label: "com.motobridge.localnet")

    /// Máximo de conexiones simultáneas (común con Apple/Android). 5 conexiones
    /// = grupo de 6 personas contándote.
    static let maxPeers = 5

    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Conexiones activas del grupo, indexadas por nombre del peer.
    private var connections: [String: NWConnection] = [:]
    private var isRunning = false

    private var discovered: [TransportPeer] = []

    init() {
        let saved = UserDefaults.standard.string(forKey: "riderName")
        self.localName = (saved?.isEmpty == false ? saved! : UIDevice.current.name)
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startListener()
        startBrowser()
        emitEvent("Universal: publicando y buscando en red local")
        setState(.notConnected)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        discovered.removeAll()
        notifyPeers()
        setState(.notConnected)
        emitEvent("Universal: detenido")
    }

    func sendAudio(_ data: Data) {
        // Enviar a TODOS los peers del grupo.
        let packet = MotoBridgePacket.encodeAudio(data)
        for conn in connections.values where conn.state == .ready {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Listener (recibe conexiones entrantes)

    private func startListener() {
        do {
            let params = NWParameters.udp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: localName, type: Self.serviceType)

            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    self?.emitEvent("Listener falló: \(err.localizedDescription)")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                // Nombre provisional por endpoint (los entrantes no traen nombre
                // de servicio); sirve como clave única en el diccionario.
                let name = "in-\(conn.endpoint)"
                self?.adopt(connection: conn, name: name, incoming: true)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            emitEvent("No se pudo crear listener: \(error.localizedDescription)")
        }
    }

    // MARK: - Browser (descubre al peer)

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: Self.serviceDomain), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint {
                    return TransportPeer(id: name, name: name)
                }
                return nil
            }
            self.notifyPeers()

            // Auto-conexión a TODOS los peers del grupo (hasta el límite).
            // Regla determinista: el nombre menor inicia; el otro espera.
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint, name != self.localName {
                    if self.connections[name] != nil { continue }         // ya conectado
                    if self.connections.count >= Self.maxPeers { break }   // grupo lleno
                    if self.localName < name {
                        self.emitEvent("Conectando a \(name)…")
                        self.connect(to: result.endpoint, name: name)
                    } else {
                        self.emitEvent("Esperando conexión de \(name)")
                    }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                self?.emitEvent("Browser falló: \(err.localizedDescription)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: - Conexión

    private func connect(to endpoint: NWEndpoint, name: String) {
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        adopt(connection: conn, name: name, incoming: false)
    }

    private func adopt(connection conn: NWConnection, name: String, incoming: Bool) {
        // Límite del grupo.
        if connections.count >= Self.maxPeers, connections[name] == nil {
            conn.cancel(); return
        }
        connections[name] = conn
        if connections.count == 1 { setState(.connecting) }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setState(.connected)
                self.emitEvent("✅ Conectado con \(name)")
                self.notifyPeers()
                self.receive(on: conn, name: name)
            case .failed(let err):
                self.emitEvent("Conexión \(name) falló: \(err.localizedDescription)")
                self.removeConnection(name)
            case .cancelled:
                self.removeConnection(name)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func removeConnection(_ name: String) {
        connections[name] = nil
        if connections.isEmpty { setState(.notConnected) }
        notifyPeers()
    }

    private func receive(on conn: NWConnection, name: String) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let audio = MotoBridgePacket.decodeAudio(data) {
                // El audio de todos los peers se entrega igual; el motor de
                // audio (AVAudioEngine) mezcla los streams automáticamente.
                self.onAudioData?(audio)
            }
            if error == nil, self.connections[name] != nil {
                self.receive(on: conn, name: name)
            }
        }
    }

    // MARK: - Notificaciones

    private func setState(_ s: TransportState) {
        DispatchQueue.main.async { self.onStateChange?(s) }
    }

    private func notifyPeers() {
        let connected = connections.keys.map { name -> TransportPeer in
            // Limpiar prefijo de entrantes para mostrar algo legible.
            let display = name.hasPrefix("in-") ? "Rider" : name
            return TransportPeer(id: name, name: display)
        }
        let disc = discovered
        DispatchQueue.main.async { self.onPeersChange?(disc, connected) }
    }

    private func emitEvent(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) · \(text)"
        log.info(.bridge, "LocalNet: \(text)")
        DispatchQueue.main.async { self.onEvent?(line) }
    }
}

/// Protocolo neutral de paquetes MotoBridge (compartido con Android).
/// Formato del datagrama de audio:
///   byte 0     : magic 'M' (0x4D)
///   byte 1     : version (0x01)
///   byte 2     : tipo (0x01 = audio PCM)
///   byte 3     : reservado (0x00)
///   bytes 4..N : PCM Int16 little-endian, mono, 8 kHz
enum MotoBridgePacket {
    static let magic: UInt8 = 0x4D  // 'M'
    static let version: UInt8 = 0x01
    static let typeAudio: UInt8 = 0x01

    static func encodeAudio(_ pcm: Data) -> Data {
        var out = Data([magic, version, typeAudio, 0x00])
        out.append(pcm)
        return out
    }

    static func decodeAudio(_ packet: Data) -> Data? {
        guard packet.count > 4,
              packet[packet.startIndex] == magic,
              packet[packet.startIndex + 2] == typeAudio else { return nil }
        return packet.subdata(in: (packet.startIndex + 4)..<packet.endIndex)
    }
}
