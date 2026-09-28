import Foundation
import MultipeerConnectivity
import Combine

/// Estado de la conexión peer-to-peer.
enum PeerConnectionState: String {
    case notConnected = "Sin conexión"
    case connecting = "Conectando"
    case connected = "Conectado"
}

/// Puente de red local entre dos dispositivos usando MultipeerConnectivity.
///
/// MultipeerConnectivity elige automáticamente el mejor transporte disponible
/// (WiFi de infraestructura, WiFi peer-to-peer directo, o Bluetooth), así que
/// funciona en el mismo WiFi, en un hotspot, o incluso sin ninguna red — sin
/// que el usuario configure nada.
///
/// Este objeto actúa a la vez como advertiser (se anuncia) y browser (busca),
/// de modo que ambos dispositivos se descubren mutuamente de forma simétrica.
final class PeerBridgeSession: NSObject, ObservableObject {

    /// Nombre de servicio: máx 15 chars, solo [a-z0-9-] (requisito de MC).
    static let serviceType = "motobridge"

    /// Máximo de riders en el grupo (común con Android). El anfitrión cuenta,
    /// así que son hasta MAX_PEERS conexiones = MAX_PEERS+1 personas... limitamos
    /// a MAX_PEERS conexiones para mantener calidad en WiFi local.
    static let maxPeers = 5   // 5 conexiones = grupo de 6 personas contando a ti

    @Published private(set) var state: PeerConnectionState = .notConnected
    @Published private(set) var discoveredPeers: [MCPeerID] = []
    @Published private(set) var connectedPeers: [MCPeerID] = []

    /// Diagnóstico visible en pantalla para depurar el descubrimiento.
    @Published private(set) var isAdvertising = false
    @Published private(set) var isBrowsing = false
    @Published private(set) var lastError: String = "—"
    /// Últimos eventos del ciclo de conexión, visibles en pantalla.
    @Published private(set) var events: [String] = []

    private func addEvent(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) · \(text)"
        DispatchQueue.main.async {
            self.events.insert(line, at: 0)
            if self.events.count > 12 { self.events.removeLast() }
            self.onEvent?(line)
        }
    }

    /// Se invoca en un hilo de fondo cuando llegan datos de audio.
    var onAudioData: ((Data) -> Void)?

    // Callbacks de AudioTransport (opcionales; la UI también puede leer los @Published).
    var onStateChange: ((TransportState) -> Void)?
    var onPeersChange: ((_ discovered: [TransportPeer], _ connected: [TransportPeer]) -> Void)?
    var onEvent: ((String) -> Void)?

    let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let log = Logger.shared

    private var isRunning = false

    override init() {
        // Nombre del rider (elegido por el usuario) o el del dispositivo.
        let saved = UserDefaults.standard.string(forKey: "riderName")
        let name = (saved?.isEmpty == false ? saved! : UIDevice.current.name)
        // MCPeerID.displayName: 1..63 UTF-8 bytes.
        let safeName = String(name.prefix(60))
        self.myPeerID = MCPeerID(displayName: safeName.isEmpty ? "Rider" : safeName)
        // .optional (no .required): el cifrado obligatorio provoca fallos de
        // handshake y desconexiones con envíos de audio frecuentes. Para audio
        // en vivo en red local, optional es mucho más estable.
        self.session = MCSession(peer: myPeerID,
                                 securityIdentity: nil,
                                 encryptionPreference: .optional)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                    discoveryInfo: nil,
                                                    serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeerID,
                                              serviceType: Self.serviceType)
        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    // MARK: - Control

    /// Empieza a anunciarse y a buscar peers.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        DispatchQueue.main.async {
            self.isAdvertising = true
            self.isBrowsing = true
            self.lastError = "—"
        }
        log.info(.bridge, "Multipeer: anunciando y buscando como \"\(myPeerID.displayName)\"")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll()
            self.connectedPeers.removeAll()
            self.state = .notConnected
            self.isAdvertising = false
            self.isBrowsing = false
        }
        log.info(.bridge, "Multipeer: detenido")
    }

    /// Invita a un peer descubierto a conectarse.
    func invite(_ peer: MCPeerID) {
        log.info(.bridge, "Multipeer: invitando a \(peer.displayName)")
        addEvent("Invitando a \(peer.displayName)")
        DispatchQueue.main.async { self.state = .connecting }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 10)
    }

    /// Reconexión automática: si seguimos activos y el peer sigue anunciándose,
    /// reintenta invitarlo tras un breve retardo. El descubrimiento nunca se
    /// detiene mientras el bridge está activo, así que reaparecerá solo.
    private func scheduleReconnect(to peerID: MCPeerID) {
        guard isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRunning else { return }
            // Solo el que tiene displayName "menor" reinvita, para no cruzar.
            guard self.myPeerID.displayName < peerID.displayName else { return }
            guard !self.session.connectedPeers.contains(peerID) else { return }
            if self.discoveredPeers.contains(peerID) {
                self.log.info(.bridge, "Multipeer: reintentando conexión con \(peerID.displayName)")
                self.addEvent("Reintentando \(peerID.displayName)…")
                self.invite(peerID)
            }
        }
    }

    // MARK: - Envío de audio

    /// Envía datos de audio a los peers conectados.
    ///
    /// Usamos modo `.reliable`: aunque en teoría `.unreliable` da menos latencia,
    /// en la práctica sus canales UDP tardan en establecerse y provocan errores
    /// "Not in connected state, giving up on channel" justo tras conectar. El modo
    /// reliable usa el canal ya establecido y es estable. Para bloques de voz
    /// pequeños la diferencia de latencia es mínima.
    func sendAudio(_ data: Data) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        // .unreliable para audio en vivo: NO satura el canal (a diferencia de
        // .reliable con muchos paquetes/segundo, que provoca desconexiones).
        // En audio es mejor perder un paquete ocasional que romper la conexión.
        do {
            try session.send(data, toPeers: peers, with: .unreliable)
        } catch {
            log.error(.bridge, "Multipeer: error al enviar audio: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCSessionDelegate

extension PeerBridgeSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers
            switch state {
            case .connected:
                self.state = .connected
                self.log.info(.bridge, "Multipeer: conectado con \(peerID.displayName)")
                self.addEvent("✅ Conectado con \(peerID.displayName)")
            case .connecting:
                self.state = .connecting
                self.addEvent("Conectando con \(peerID.displayName)…")
            case .notConnected:
                self.state = session.connectedPeers.isEmpty ? .notConnected : .connected
                self.log.warning(.bridge, "Multipeer: \(peerID.displayName) desconectado")
                self.addEvent("❌ Desconectado \(peerID.displayName)")
                // Reconexión automática: si seguimos activos y el peer sigue
                // descubierto, reintentar la invitación tras un breve retardo.
                self.scheduleReconnect(to: peerID)
            @unknown default:
                break
            }
            self.notifyTransportState()
        }
    }

    /// Notifica el estado y los peers a los callbacks de AudioTransport.
    private func notifyTransportState() {
        let ts: TransportState
        switch state {
        case .connected: ts = .connected
        case .connecting: ts = .connecting
        case .notConnected: ts = .notConnected
        }
        onStateChange?(ts)
        let discovered = discoveredPeers.map { TransportPeer(id: $0.displayName, name: $0.displayName) }
        let connected = connectedPeers.map { TransportPeer(id: $0.displayName, name: $0.displayName) }
        onPeersChange?(discovered, connected)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Llega en hilo de fondo; lo pasamos directo al reproductor de audio.
        onAudioData?(data)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerBridgeSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Aceptar solo si no llegamos al límite del grupo.
        if session.connectedPeers.count >= Self.maxPeers {
            log.warning(.bridge, "Multipeer: grupo lleno, rechazando \(peerID.displayName)")
            addEvent("Grupo lleno, rechazado \(peerID.displayName)")
            invitationHandler(false, nil)
            return
        }
        log.info(.bridge, "Multipeer: invitación recibida de \(peerID.displayName), aceptando")
        addEvent("Invitación recibida de \(peerID.displayName)")
        DispatchQueue.main.async { self.state = .connecting }
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didNotStartAdvertisingPeer error: Error) {
        log.error(.bridge, "Multipeer: fallo al anunciar: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isAdvertising = false
            self.lastError = "Anuncio: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerBridgeSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.discoveredPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
        }
        log.info(.bridge, "Multipeer: peer encontrado \(peerID.displayName)")
        addEvent("Encontrado \(peerID.displayName)")

        // Auto-invitación determinista para evitar doble invitación cruzada:
        // solo invita el que tenga el displayName "menor". El otro aceptará.
        // Si ya estamos conectados a este peer, no reinvitar.
        guard !session.connectedPeers.contains(peerID) else { return }
        // No invitar si el grupo ya está lleno.
        guard session.connectedPeers.count < Self.maxPeers else {
            addEvent("Grupo lleno, no invito a \(peerID.displayName)")
            return
        }
        if myPeerID.displayName < peerID.displayName {
            invite(peerID)
        } else {
            addEvent("Esperando invitación de \(peerID.displayName)")
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll { $0 == peerID }
        }
        log.warning(.bridge, "Multipeer: peer perdido \(peerID.displayName)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log.error(.bridge, "Multipeer: fallo al buscar: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isBrowsing = false
            self.lastError = "Búsqueda: \(error.localizedDescription)"
        }
    }
}


// MARK: - AudioTransport

extension PeerBridgeSession: AudioTransport {
    var mode: TransportMode { .apple }
    var localName: String { myPeerID.displayName }
}
