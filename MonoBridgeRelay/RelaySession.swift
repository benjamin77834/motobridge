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
    /// altitudeMeters/batteryPercent llegan solo cuando el rider tiene activo el
    /// Modo Rescate en su teléfono (los manda en el latido de presencia).
    struct RiderNode: Identifiable {
        var id: String { name }
        let name: String
        var hops: Int
        var lastSeen: Date
        var altitudeMeters: Double? = nil
        var batteryPercent: Int? = nil
        /// Rastro: historial de cercanía (menos saltos = más cerca). Guardamos
        /// como "proximidad" 0..1 (1 = pegado, 0 = lejos) para la mini-gráfica.
        var trail: [Double] = []
        enum Level { case near, far, lost }
        var level: Level {
            let age = Date().timeIntervalSince(lastSeen)
            if age > 8 { return .lost }
            return hops <= 1 ? .near : .far
        }
        /// Tendencia según el rastro: +1 acercándose, -1 alejándose, 0 estable.
        var trend: Int {
            guard trail.count >= 3 else { return 0 }
            let recent = Array(trail.suffix(5))
            let first = recent.first!, last = recent.last!
            if last - first > 0.08 { return 1 }
            if first - last > 0.08 { return -1 }
            return 0
        }
    }

    /// Altura barométrica de referencia del propio nodo Mac. La Mac no tiene
    /// barómetro, así que usamos la PRIMERA altura recibida como cero relativo
    /// para mostrar diferencias entre riders de forma coherente. nil hasta que
    /// llegue el primer dato.
    private var referenceAltitude: Double?

    /// Nombre visible de este nodo Mac en la malla.
    let localName: String

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let mesh = MeshRelay()

    // Audio: la Mac como participante de voz (puesto base).
    private let audio = RelayAudio()
    /// ¿El micrófono de la Mac está transmitiendo? (botón "Hablar").
    @Published private(set) var talking = false
    /// ¿El audio de la Mac está disponible (permiso concedido + engine OK)?
    @Published private(set) var audioReady = false

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
        // El micrófono capturado se envía a los peers como audio de grupo, con
        // el MISMO formato que iOS (VoiceChannel group + PCM), y se relaya.
        audio.onCapturedAudio = { [weak self] packet in
            guard let self else { return }
            let channeled = VoiceChannel.wrap(packet, type: .group, targetId: 0)
            let out = self.mesh.wrapOutgoing(channeled)
            let peers = self.session.connectedPeers
            if !peers.isEmpty { try? self.session.send(out, toPeers: peers, with: .unreliable) }
        }
    }

    // MARK: - Control

    func start() {
        guard !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        addEvent("Relay iniciado como \"\(localName)\"")
        // Arrancar audio (pide permiso de micrófono la primera vez).
        RelayAudio.requestMicPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                do { try self.audio.start(); self.audioReady = true
                     self.addEvent("Audio listo (puedes hablar)") }
                catch { self.addEvent("No se pudo iniciar audio: \(error.localizedDescription)") }
            } else {
                self.audioReady = false
                self.addEvent("Sin permiso de micrófono: solo monitoreo")
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        audio.isTransmitting = false
        audio.stop()
        DispatchQueue.main.async {
            self.connectedPeers = []
            self.riders = []
            self.talking = false
            self.audioReady = false
        }
        addEvent("Relay detenido")
    }

    func toggle() { running ? stop() : start() }

    /// Activa/desactiva el micrófono de la Mac (botón "Hablar" toggle).
    func toggleTalk() {
        guard audioReady else { return }
        setTalking(!talking)
    }

    /// Abre/cierra el micrófono directamente. Lo usa el PUSH-TO-TALK: abrir al
    /// presionar, cerrar al soltar. PTT evita el eco porque el micrófono solo
    /// está abierto mientras de verdad hablas (no de forma continua).
    func setTalking(_ on: Bool) {
        guard audioReady, talking != on else { return }
        talking = on
        audio.isTransmitting = on
        addEvent(on ? "🎙️ Micrófono ABIERTO" : "Micrófono en silencio")
    }

    // MARK: - Radar

    private func noteRiderSeen(_ name: String, hops: Int,
                               altitudeMeters: Double? = nil, batteryPercent: Int? = nil) {
        guard name != localName else { return }
        if let a = altitudeMeters, referenceAltitude == nil { referenceAltitude = a }
        // Proximidad 0..1 a partir de los saltos: 0 saltos = 1.0 (pegado),
        // y baja al aumentar saltos. Es la muestra que alimenta el rastro.
        let proximity = max(0.0, 1.0 - Double(hops) / 6.0)
        DispatchQueue.main.async {
            if let i = self.riders.firstIndex(where: { $0.name == name }) {
                self.riders[i].hops = hops
                self.riders[i].lastSeen = Date()
                if let a = altitudeMeters { self.riders[i].altitudeMeters = a }
                if let b = batteryPercent { self.riders[i].batteryPercent = b }
                self.riders[i].trail.append(proximity)
                if self.riders[i].trail.count > 40 { self.riders[i].trail.removeFirst() }
            } else {
                var node = RiderNode(name: name, hops: hops, lastSeen: Date(),
                                     altitudeMeters: altitudeMeters, batteryPercent: batteryPercent)
                node.trail = [proximity]
                self.riders.append(node)
            }
        }
    }

    /// Diferencia de altura (m) de un nodo respecto a la referencia del relay.
    /// Positivo = ARRIBA; negativo = ABAJO. nil si falta dato. ~3 m por piso.
    func floors(for node: RiderNode) -> Int? {
        guard let a = node.altitudeMeters, let ref = referenceAltitude else { return nil }
        return Int(((a - ref) / 3.0).rounded())
    }
    func metersDelta(for node: RiderNode) -> Double? {
        guard let a = node.altitudeMeters, let ref = referenceAltitude else { return nil }
        return a - ref
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

    /// Interpreta el payload de la malla: alimenta el radar con la PRESENCIA y
    /// REPRODUCE el audio de grupo entrante (la Mac ahora es puesto de voz).
    private func handlePayload(_ data: Data, hops: Int) {
        guard let msg = VoiceChannel.unwrap(data) else {
            // Sin cabecera de canal: tratar como audio de grupo crudo.
            audio.play(data)
            return
        }
        // Audio de grupo → reproducir por las bocinas de la Mac.
        if msg.type == .group {
            audio.play(msg.audio)
            return
        }
        if msg.type == .presence {
            // Primera línea = nombre; líneas ALT=/BAT= = datos del Modo Rescate.
            guard let text = String(data: msg.audio, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard let first = lines.first, !first.isEmpty else { return }
            var alt: Double? = nil
            var bat: Int? = nil
            for line in lines.dropFirst() {
                if line.hasPrefix("ALT=") { alt = Double(line.dropFirst(4)) }
                else if line.hasPrefix("BAT=") { bat = Int(line.dropFirst(4)) }
            }
            noteRiderSeen(String(first), hops: hops, altitudeMeters: alt, batteryPercent: bat)
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
