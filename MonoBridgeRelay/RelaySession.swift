import Foundation
import MultipeerConnectivity
import Combine

/// Nodo de malla para macOS: "Mono Bridge Relay".
///
/// La Mac entra a la MISMA malla que los iPhones (canal Apple/Multipeer con el
/// serviceType "mbapple", igual que la app de iOS) y hace de NODO participante:
///  - Se anuncia como un peer más → los iPhones la ven en su radar.
///  - RELAYA la malla: reenvía a sus vecinos lo que recibe de otros, extendiendo
///    el alcance encadenado (útil en emergencias: nodo fijo que no se apaga).
///  - Muestra su propio radar de riders/nodos conectados (centro de monitoreo).
///
/// NO captura ni reproduce audio y NO usa sensores. Es deliberadamente un nodo
/// de red: repetir + ver, no hablar.
final class RelaySession: NSObject, ObservableObject {

    /// Debe ser EXACTAMENTE el mismo serviceType que la app iOS (canal Apple).
    static let serviceType = "mbapple"
    static let maxPeers = 7   // la Mac aguanta más conexiones que un teléfono

    @Published private(set) var running = false
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var riders: [RiderNode] = []
    @Published private(set) var relayedPackets = 0
    @Published private(set) var events: [String] = []

    /// Un nodo visto en la malla (rider o repetidor), con su última señal.
    struct RiderNode: Identifiable {
        var id: String { name }
        let name: String
        var hops: Int
        var lastSeen: Date
        enum Level { case near, far, lost }
        var level: Level {
            let age = Date().timeIntervalSince(lastSeen)
            if age > 8 { return .lost }
            return hops <= 1 ? .near : .far
        }
    }

    /// Nombre visible de este nodo Mac en la malla.
    let localName: String

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let mesh = MeshRelay()

    override init() {
        let saved = UserDefaults.standard.string(forKey: "relayName")
        let host = Host.current().localizedName ?? "Mac Relay"
        let name = (saved?.isEmpty == false ? saved! : "📡 \(host)")
        self.localName = String(name.prefix(60))
        self.myPeerID = MCPeerID(displayName: localName.isEmpty ? "Mac Relay" : localName)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .optional)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    // MARK: - Control

    func start() {
        guard !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        addEvent("Relay iniciado como \"\(localName)\"")
    }

    func stop() {
        guard running else { return }
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        DispatchQueue.main.async {
            self.connectedPeers = []
            self.riders = []
        }
        addEvent("Relay detenido")
    }

    func toggle() { running ? stop() : start() }

    // MARK: - Radar

    private func noteRiderSeen(_ name: String, hops: Int) {
        guard name != localName else { return }
        DispatchQueue.main.async {
            if let i = self.riders.firstIndex(where: { $0.name == name }) {
                self.riders[i].hops = hops
                self.riders[i].lastSeen = Date()
            } else {
                self.riders.append(RiderNode(name: name, hops: hops, lastSeen: Date()))
            }
        }
    }

    private func addEvent(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) · \(text)"
        DispatchQueue.main.async {
            self.events.insert(line, at: 0)
            if self.events.count > 30 { self.events.removeLast() }
        }
    }
}

// MARK: - MCSessionDelegate

extension RelaySession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers.map { $0.displayName }
        }
        switch state {
        case .connected:
            addEvent("✅ Conectado con \(peerID.displayName)")
            noteRiderSeen(peerID.displayName, hops: 0)
        case .connecting:
            addEvent("Conectando con \(peerID.displayName)…")
        case .notConnected:
            addEvent("❌ Desconectado \(peerID.displayName)")
        @unknown default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Procesar por la malla: deduplicar, reproducir (aquí = anotar presencia)
        // y REENVIAR a los demás vecinos para extender el alcance.
        if let incoming = mesh.processIncoming(data) {
            if incoming.isNew {
                handlePayload(incoming.payload, hops: incoming.hops)
            }
            // Relay: reenviar a los OTROS peers conectados (no al emisor).
            if let relay = incoming.relay {
                let others = session.connectedPeers.filter { $0 != peerID }
                if !others.isEmpty {
                    try? session.send(relay, toPeers: others, with: .unreliable)
                    DispatchQueue.main.async { self.relayedPackets += 1 }
                }
            }
        } else {
            // Paquete sin cabecera de malla: igual lo reenviamos a los demás.
            let others = session.connectedPeers.filter { $0 != peerID }
            if !others.isEmpty {
                try? session.send(data, toPeers: others, with: .unreliable)
                DispatchQueue.main.async { self.relayedPackets += 1 }
            }
            handlePayload(data, hops: 0)
        }
    }

    /// Interpreta el payload de la malla para alimentar el radar. Solo nos
    /// interesa el latido de PRESENCIA (nombre del rider); el audio se ignora
    /// (este nodo no reproduce), pero ya fue reenviado arriba.
    private func handlePayload(_ data: Data, hops: Int) {
        guard let msg = VoiceChannel.unwrap(data) else { return }
        if msg.type == .presence {
            // La primera línea del payload es el nombre del rider.
            if let text = String(data: msg.audio, encoding: .utf8),
               let first = text.split(separator: "\n", omittingEmptySubsequences: false).first,
               !first.isEmpty {
                noteRiderSeen(String(first), hops: hops)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser / Browser

extension RelaySession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let accept = session.connectedPeers.count < Self.maxPeers
        addEvent(accept ? "Invitación de \(peerID.displayName), aceptando" : "Lleno, rechazo \(peerID.displayName)")
        invitationHandler(accept, accept ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        addEvent("Fallo al anunciar: \(error.localizedDescription)")
    }
}

extension RelaySession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        addEvent("Encontrado \(peerID.displayName)")
        guard !session.connectedPeers.contains(peerID) else { return }
        guard session.connectedPeers.count < Self.maxPeers else { return }
        // Desempate determinista: invita el displayName menor; empate por hash.
        let me = myPeerID.displayName, other = peerID.displayName
        let iInvite = me != other ? (me < other) : (me.hashValue < peerID.hashValue)
        if iInvite {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
            addEvent("Invitando a \(peerID.displayName)")
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        addEvent("Perdido \(peerID.displayName)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        addEvent("Fallo al buscar: \(error.localizedDescription)")
    }
}
