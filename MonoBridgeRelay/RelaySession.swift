import Foundation
import MultipeerConnectivity
import AVFoundation
import Combine
import os

private let slog = os.Logger(subsystem: "com.motobridge.relay", category: "session")

/// Nodo de malla para macOS: "Mono Bridge Relay".
///
/// La Mac entra a la MISMA malla que los iPhones (canal Apple/Multipeer con el
/// serviceType "mbapple", igual que la app de iOS) y hace de NODO participante:
///  - Se anuncia como un peer más → los iPhones la ven en su radar.
///  - RELAYA la malla: reenvía a sus vecinos lo que recibe de otros, extendiendo
///    el alcance encadenado (útil en emergencias: nodo fijo que no se apaga).
///  - Muestra su propio radar de riders/nodos conectados (centro de monitoreo).
///
/// Además corre en paralelo el canal "Universal" (UDP + Bonjour `_motobridge._udp`,
/// ver PROTOCOL.md) para ver y hablar con dispositivos Android, y RELAYA entre
/// ambos canales (presencia, alarma y mensajes) uniendo iPhones y Android. En
/// Universal v1 NO hay audio en vivo (solo presencia, alarma y mensajes).
final class RelaySession: NSObject, ObservableObject {

    /// Debe ser EXACTAMENTE el mismo serviceType que la app iOS (canal Apple).
    static let serviceType = "mbapple"
    static let maxPeers = 7   // la Mac aguanta más conexiones que un teléfono

    @Published private(set) var running = false
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var riders: [RiderNode] = []
    @Published private(set) var relayedPackets = 0
    @Published private(set) var events: [String] = []
    /// Dispositivos del canal Universal (Android u otros) conectados por red local.
    @Published private(set) var universalPeers: [String] = []

    /// Todos los dispositivos con los que se puede hablar (Multipeer + Universal).
    var allPeers: [String] {
        connectedPeers + universalPeers.filter { !connectedPeers.contains($0) }
    }

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
    /// Peers a los que ya invitamos (para no invitar doble y evitar el cruce
    /// que provoca ForceDisconnect). Se limpia al conectar o perder el peer.
    private var invitedPeers = Set<MCPeerID>()
    private var payloadLogCount = 0

    // MARK: Canal Universal (Android)
    private let universal: UniversalTransport
    private var presenceTimer: Timer?
    /// Estado compartido entre hilos (Multipeer y Universal), protegido por lock.
    private let stateLock = NSLock()
    private var universalKeys: [String] = []
    /// Nombre real de cada conexión Universal (se aprende del latido de presencia).
    private var universalAliases: [String: String] = [:]
    /// Paquetes de control sin ID de malla ya vistos (huella → cuándo). Evita
    /// bucles al repetir entre canales, igual que MeshRelay lo hace con IDs.
    private var directSeen: [Int: Date] = [:]
    private static let dedupWindow: TimeInterval = 1.0
    /// Actividad que mantiene el sistema despierto mientras el nodo está activo.
    private var activity: NSObjectProtocol?

    // MARK: Buscar dispositivos (igual que en iPhone)

    /// ID único y estable de esta Mac. Se manda al anunciarse y sirve para el
    /// desempate de "quién invita" (mismo criterio que la app iPhone).
    static let deviceUID: String = {
        if let saved = UserDefaults.standard.string(forKey: "relayDeviceUID") { return saved }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "relayDeviceUID")
        return new
    }()
    private var peerUIDs: [MCPeerID: String] = [:]
    private var foundPeers: [MCPeerID] = []

    /// ¿Está escaneando (anunciándose + buscando)? Apagado ahorra batería.
    @Published private(set) var scanning = false
    /// Dispositivos descubiertos que aún no están conectados (para el botón Conectar).
    @Published private(set) var nearby: [String] = []

    /// Conexión automática (se une sola, como antes) o manual (tú eliges a cuál).
    @Published var autoConnect: Bool = (UserDefaults.standard.object(forKey: "relayAutoConnect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "relayAutoConnect") }
    }

    func startScan() {
        guard running, !scanning else { return }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        universal.start()
        startPresenceTimer()
        scanning = true
        addEvent("Escaneo ON")
    }

    func stopScan() {
        guard scanning else { return }
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        universal.stop()
        presenceTimer?.invalidate(); presenceTimer = nil
        scanning = false
        addEvent("Escaneo OFF (ahorro de batería)")
    }

    func toggleScan() { scanning ? stopScan() : startScan() }

    /// Conecta a un dispositivo de la lista (botón Conectar). La invitación lleva
    /// un "pickup" ("X quiere conectarse") en el contexto: el otro lado suena un
    /// timbre suave y acepta. Los peers viejos ignoran el contexto.
    func connect(toName name: String) {
        guard let peer = foundPeers.first(where: { $0.displayName == name }),
              !session.connectedPeers.contains(peer), !invitedPeers.contains(peer) else { return }
        invitedPeers.insert(peer)
        let pickup = VoiceChannel.wrapPickup(from: localName, to: Self.idFor(name: name))
        browser.invitePeer(peer, to: session, withContext: pickup, timeout: 15)
        addEvent("Invitando a \(name) (pickup)")
    }

    // MARK: Pickup y timbre

    /// Aviso visible "X quiere conectarse" (se borra solo).
    @Published private(set) var pickupNotice: String?
    private var lastPickup: [String: Date] = [:]
    private var pickupClearWork: DispatchWorkItem?
    /// Quién nos invitó con pickup hace poco (no lo invitamos de vuelta: evita cruce).
    private var invitedByAt: [MCPeerID: Date] = [:]
    private var chimePlayer: AVAudioPlayer?

    private func recentlyInvitedBy(_ peer: MCPeerID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let t = invitedByAt[peer] else { return false }
        return Date().timeIntervalSince(t) < 12
    }

    /// Timbre sintetizado (sin assets), volumen bajo. AVAudioPlayer es
    /// independiente del motor de voz de la Mac y no abre el micrófono.
    private func playChime(_ kind: ChimeSynth.Kind) {
        DispatchQueue.main.async {
            guard let player = try? AVAudioPlayer(data: ChimeSynth.wav(kind)) else { return }
            player.volume = 0.3
            player.prepareToPlay()
            player.play()
            self.chimePlayer = player
        }
    }

    /// Pickup recibido (invitación Multipeer o paquete Universal). Repetidos del
    /// mismo emisor en 8 s se ignoran (puede llegar por los dos canales).
    private func handlePickup(from name: String) {
        DispatchQueue.main.async {
            let now = Date()
            if let t = self.lastPickup[name], now.timeIntervalSince(t) < 8 { return }
            self.lastPickup[name] = now
            self.addEvent("📞 \(name) quiere conectarse")
            self.pickupNotice = "\(name) quiere conectarse"
            self.playChime(.pickup)
            self.pickupClearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.pickupNotice = nil }
            self.pickupClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private func refreshNearby() {
        let list = foundPeers
            .filter { !session.connectedPeers.contains($0) }
            .map { $0.displayName }
        DispatchQueue.main.async { self.nearby = list }
    }

    // Audio: la Mac como participante de voz (puesto base).
    private let audio = RelayAudio()
    /// ¿El micrófono de la Mac está transmitiendo? (botón "Hablar").
    @Published private(set) var talking = false
    /// ¿El audio de la Mac está disponible (permiso concedido + engine OK)?
    @Published private(set) var audioReady = false

    override init() {
        let saved = UserDefaults.standard.string(forKey: "relayName")
        let host = Host.current().localizedName ?? "Mac Relay"
        // Sin emoji: caracteres no-ASCII en el displayName descolocan la regla
        // de desempate de invitacion (nombre "menor") y causan cruce de sesiones.
        let base = (saved?.isEmpty == false ? saved! : "Mac \(host)")
        self.localName = String(base.prefix(60))
        self.myPeerID = MCPeerID(displayName: localName.isEmpty ? "Mac Relay" : localName)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .optional)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["uid": Self.deviceUID], serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        self.universal = UniversalTransport(localName: self.localName.isEmpty ? "Mac Relay" : self.localName)
        super.init()
        universal.onPacket = { [weak self] data, key in self?.handleUniversal(data, key: key) }
        universal.onPeersChange = { [weak self] keys in
            guard let self else { return }
            self.stateLock.lock()
            self.universalKeys = keys
            self.universalAliases = self.universalAliases.filter { keys.contains($0.key) }
            self.stateLock.unlock()
            self.publishUniversalPeers()
        }
        universal.onEvent = { [weak self] line in self?.addEvent("[Universal] " + line) }
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
        // Evitar que macOS duerma el equipo o suspenda la app (App Nap) mientras el
        // nodo está encendido: con la pantalla apagada se cortaba la conexión. La
        // pantalla SÍ puede apagarse; lo que se mantiene despierto es el sistema.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Mono Bridge Relay: nodo de malla activo")
        // Automático: escanea de una vez. Manual: queda sin escanear hasta que
        // pulses "Buscar dispositivos" (ahorra batería, igual que en iPhone).
        if autoConnect { startScan() }
        addEvent("Relay iniciado como \"\(localName)\"")
        // IMPORTANTE: el audio (engine de micrófono) NO arranca aquí. Correr el
        // engine de captura de forma continua interfiere con Multipeer y provoca
        // desconexiones. El micrófono se enciende SOLO al pulsar HABLAR (ver
        // toggleTalk/setTalking). Así el nodo queda estable para alarma y
        // mensajes (lo confiable), y el audio entra bajo demanda.
        audioReady = false
    }

    func stop() {
        guard running else { return }
        running = false
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        universal.stop()
        presenceTimer?.invalidate(); presenceTimer = nil
        session.disconnect()
        audio.isTransmitting = false
        audio.stop()
        foundPeers.removeAll()
        invitedPeers.removeAll()
        DispatchQueue.main.async {
            self.connectedPeers = []
            self.universalPeers = []
            self.riders = []
            self.nearby = []
            self.scanning = false
            self.talking = false
            self.audioReady = false
        }
        addEvent("Relay detenido")
    }

    func toggle() { running ? stop() : start() }

    /// Envía un MENSAJE de texto al grupo. El iPhone lo lee por voz (TTS). Es un
    /// paquete corto y puntual, mucho más confiable que el audio continuo.
    /// ID derivado del nombre (FNV-1a), IDÉNTICO al de la app iPhone
    /// (NetworkBridgeController.idFor). Así el iPhone reconoce que un mensaje
    /// privado es para él.
    static func idFor(name: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return hash
    }

    /// Envía un MENSAJE de texto. `to` = nombre de la persona (privado) o nil
    /// para todo el grupo. El iPhone lo lee por voz. Al privado solo lo lee
    /// quien tenga ese nombre; se manda por la malla y solo al peer si está
    /// conectado directo (si no, a todos y cada uno filtra por su id).
    func sendMessage(_ text: String, to name: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let payload = clean.data(using: .utf8) else { return }
        let target = name.map { Self.idFor(name: $0) } ?? 0
        let channeled = VoiceChannel.wrap(payload, type: .text, targetId: target)
        let all = session.connectedPeers
        let uTargets = universalTargets(for: name, directMultipeer: all.contains { $0.displayName == name })
        guard !all.isEmpty || uTargets.hasPeers else { addEvent("Sin peers para el mensaje"); return }
        // Privado a alguien conectado directo: solo a ese peer (más discreto).
        var peers = all
        if let name, let direct = all.first(where: { $0.displayName == name }) { peers = [direct] }
        if !peers.isEmpty { try? session.send(channeled, toPeers: peers, with: .reliable) }
        sendUniversal(channeled, keys: uTargets.keys)
        addEvent(name == nil ? "✉️ Mensaje al grupo: \(clean)" : "✉️ Mensaje a \(name!): \(clean)")
    }

    /// Botón de ALARMA: el iPhone la recibe con PRIORIDAD y la anuncia por voz
    /// ("Emergencia. Un rider necesita ayuda"), aunque esté en música/privado.
    /// Payload VACÍO: el iPhone, al recibir .alarm, solo reproduce audio si lo
    /// hay; sin payload no mete ruido, pero sí dispara el aviso de voz. Además
    /// mandamos un texto explícito para que quede claro de quién viene.
    func sendAlarm() {
        let peers = session.connectedPeers
        guard !peers.isEmpty || universalTargets(for: nil, directMultipeer: false).hasPeers else {
            addEvent("Sin peers para la alarma"); return
        }
        // 1) Alarma (prioridad + aviso de voz genérico en el iPhone/Android).
        let alarm = VoiceChannel.wrap(Data(), type: .alarm, targetId: 0)
        if !peers.isEmpty { try? session.send(alarm, toPeers: peers, with: .reliable) }
        sendUniversal(alarm, keys: nil)
        // 2) Texto con el detalle (se lee por voz): quién y qué.
        if let payload = "Emergencia. Alerta desde \(localName)".data(using: .utf8) {
            let txt = VoiceChannel.wrap(payload, type: .text, targetId: 0)
            if !peers.isEmpty { try? session.send(txt, toPeers: peers, with: .reliable) }
            sendUniversal(txt, keys: nil)
        }
        addEvent("🚨 ALARMA enviada al grupo")
    }

    /// Activa/desactiva el micrófono de la Mac (botón "Hablar" toggle).
    /// Enciende/apaga el AUDIO (engine de voz: oír + poder hablar). Arranca
    /// APAGADO. Mientras está apagado, el nodo solo hace alarma/mensajes/radar,
    /// que es LO ESTABLE. El audio en vivo (que desestabiliza Multipeer) solo
    /// corre cuando tú lo enciendes aquí. Pide permiso de micrófono la 1ª vez.
    func toggleAudio() {
        if audioReady { stopAudio() } else { startAudio() }
    }

    private func startAudio() {
        RelayAudio.requestMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.addEvent("Sin permiso de micrófono (Ajustes → Privacidad)"); return }
            do {
                try self.audio.start()
                self.audioReady = true
                self.addEvent("🔊 Audio ENCENDIDO (oyes y puedes hablar)")
            } catch {
                self.addEvent("No se pudo iniciar audio: \(error.localizedDescription)")
            }
        }
    }

    private func stopAudio() {
        audio.isTransmitting = false
        audio.stop()
        talking = false
        audioReady = false
        addEvent("🔇 Audio apagado (solo alarma y mensajes)")
    }

    func toggleTalk() { setTalking(!talking) }

    /// Abre/cierra el micrófono para TRANSMITIR (el audio ya debe estar
    /// encendido). Lo usa el push-to-talk.
    func setTalking(_ on: Bool) {
        guard audioReady, talking != on else { return }
        talking = on
        audio.isTransmitting = on
        addEvent(on ? "🎙️ Hablando…" : "Micrófono en silencio")
    }

    // MARK: - Canal Universal

    /// Latido de presencia por Universal cada 2 s (igual que iOS/Android) para que
    /// los Android vean a la Mac en su radar. Payload: nombre de la Mac.
    private func startPresenceTimer() {
        presenceTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let payload = self.localName.data(using: .utf8) else { return }
            self.sendUniversal(VoiceChannel.wrap(payload, type: .presence, targetId: 0), keys: nil)
        }
        RunLoop.main.add(t, forMode: .common)
        presenceTimer = t
    }

    /// Envía por Universal un paquete propio (sin cabecera de malla, como hace iOS
    /// con la malla apagada). Se marca como visto para descartar su rebote.
    private func sendUniversal(_ data: Data, keys: [String]?) {
        _ = markSeen(data)
        stateLock.lock(); let has = !universalKeys.isEmpty; stateLock.unlock()
        guard has else { return }
        universal.send(data, toKeys: keys)
    }

    /// A qué conexiones Universal va un mensaje. Privado a un Android: solo a él
    /// (una clave por dispositivo, porque puede haber dos conexiones al mismo).
    /// Privado a un iPhone directo: no sale por Universal. Grupo: a todos.
    private func universalTargets(for name: String?, directMultipeer: Bool) -> (hasPeers: Bool, keys: [String]?) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !universalKeys.isEmpty else { return (false, nil) }
        guard let name else { return (true, uniqueKeysLocked()) }
        let matches = universalKeys.filter { universalAliases[$0] == name }
        if !matches.isEmpty { return (true, [matches.sorted().first!]) }
        if directMultipeer { return (false, nil) }
        return (true, uniqueKeysLocked())
    }

    /// Una clave por dispositivo conocido (evita mensajes dobles) + las sin alias.
    private func uniqueKeysLocked() -> [String] {
        var seenAlias = Set<String>()
        var out: [String] = []
        for k in universalKeys.sorted() {
            if let a = universalAliases[k] {
                if seenAlias.insert(a).inserted { out.append(k) }
            } else { out.append(k) }
        }
        return out
    }

    private func publishUniversalPeers() {
        stateLock.lock()
        var names: [String] = []
        for k in universalKeys.sorted() {
            let n = universalAliases[k] ?? Self.unnamedUniversal
            if !names.contains(n) { names.append(n) }
        }
        stateLock.unlock()
        DispatchQueue.main.async {
            // Timbre suave si ya había gente y aparece un dispositivo Universal nuevo
            // (ya identificado por nombre; el marcador genérico no cuenta).
            let known = self.universalPeers.filter { $0 != Self.unnamedUniversal }
            let added = names.filter { $0 != Self.unnamedUniversal && !known.contains($0) }
            if !added.isEmpty, !self.connectedPeers.isEmpty || !known.isEmpty { self.playChime(.connected) }
            self.universalPeers = names
        }
    }

    private static let unnamedUniversal = "Dispositivo en red local"

    /// Huella de un paquete sin ID de malla. true = nuevo; false = ya visto hace
    /// menos de `dedupWindow` s (rebote entre canales o duplicado por dos rutas).
    private func markSeen(_ data: Data) -> Bool {
        let key = data.hashValue &+ data.count
        let now = Date()
        stateLock.lock(); defer { stateLock.unlock() }
        if directSeen.count > 512 { directSeen = directSeen.filter { now.timeIntervalSince($0.value) < Self.dedupWindow } }
        if let t = directSeen[key], now.timeIntervalSince(t) < Self.dedupWindow { return false }
        directSeen[key] = now
        return true
    }

    /// Paquete llegado por Universal (Android/iPhone en red local). Puede venir
    /// directo (magic 0x56, lo normal) o envuelto en malla (9 bytes de cabecera).
    private func handleUniversal(_ data: Data, key: String) {
        if data.first == VoiceChannel.magic {
            handlePayload(data, hops: 0, universalKey: key)
        } else if let inc = mesh.processIncoming(data), inc.isNew {
            // Desenvuelto para uso local; al lado Multipeer va el paquete de malla
            // con TTL-1 (mismo mecanismo de IDs/TTL que MeshRelay), sin duplicarlo.
            _ = markSeen(inc.payload)
            handlePayload(inc.payload, hops: inc.hops, universalKey: key, forward: false)
            let peers = session.connectedPeers
            if let relay = inc.relay, !peers.isEmpty, isControl(inc.payload) {
                try? session.send(relay, toPeers: peers, with: .reliable)
                DispatchQueue.main.async { self.relayedPackets += 1 }
            }
        }
    }

    /// Tipos que viajan entre canales en v1 (todo menos audio en vivo).
    private func isControl(_ data: Data) -> Bool {
        guard let m = VoiceChannel.unwrap(data) else { return false }
        switch m.type {
        case .group, .privateWhisper: return false
        case .subgroup: return m.isText
        default: return true
        }
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
        refreshNearby()   // los conectados salen de "cercanos"; los caídos vuelven
        switch state {
        case .connected:
            invitedPeers.remove(peerID)   // conexión lograda, ya no "pendiente"
            // Timbre suave si ya había gente conectada y llega alguien nuevo.
            let others = session.connectedPeers.filter { $0 != peerID }
            DispatchQueue.main.async {
                if !others.isEmpty || self.universalPeers.contains(where: { $0 != Self.unnamedUniversal }) {
                    self.playChime(.connected)
                }
            }
            addEvent("✅ Conectado con \(peerID.displayName)")
            noteRiderSeen(peerID.displayName, hops: 0)
        case .connecting:
            addEvent("Conectando con \(peerID.displayName)…")
        case .notConnected:
            invitedPeers.remove(peerID)
            addEvent("❌ Desconectado \(peerID.displayName)")
            // No reinvitamos: la Mac solo acepta. El iPhone (que sí busca e
            // invita) volverá a invitar solo cuando nos vea.
        @unknown default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // El paquete puede venir de dos formas:
        //  a) DIRECTO (mesh off, lo normal): empieza con el magic de VoiceChannel
        //     (0x56). Se procesa tal cual, SIN tocar la capa de malla.
        //  b) ENVUELTO en malla (mesh on): 9 bytes de cabecera + VoiceChannel.
        // Detectamos por el primer byte: si es 0x56, es directo; si no, es malla.
        let isDirect = (data.first == VoiceChannel.magic)
        if isDirect {
            handlePayload(data, hops: 0)
            return
        }
        // Envuelto en malla: desenvolver, reproducir y (si procede) relayar.
        if let incoming = mesh.processIncoming(data) {
            // Si el paquete llega de un peer CONECTADO DIRECTO a la Mac, son 0
            // saltos (está pegado), aunque el TTL de malla diga otra cosa. Solo
            // usamos los hops de malla si el emisor NO es un peer directo.
            let directHops = session.connectedPeers.contains(peerID) ? 0 : incoming.hops
            if incoming.isNew { handlePayload(incoming.payload, hops: directHops) }
            let others = session.connectedPeers.filter { $0 != peerID }
            if let relay = incoming.relay, others.count >= 1, session.connectedPeers.count >= 2 {
                try? session.send(relay, toPeers: others, with: .unreliable)
                DispatchQueue.main.async { self.relayedPackets += 1 }
            }
        }
    }

    /// Interpreta el payload de la malla: alimenta el radar con la PRESENCIA y
    /// REPRODUCE el audio de grupo entrante (la Mac ahora es puesto de voz).
    private func handlePayload(_ data: Data, hops: Int, universalKey: String? = nil, forward: Bool = true) {
        payloadLogCount += 1
        // Pickup ("X quiere conectarse"): va dirigido a un dispositivo, no se repite
        // entre canales. Los pickups de otros destinatarios se ignoran.
        if let p = VoiceChannel.parsePickup(data) {
            if p.targetId == 0 || p.targetId == Self.idFor(name: localName) { handlePickup(from: p.sender) }
            return
        }
        // Universal v1 no trae audio en vivo: se descarta el audio y lo crudo.
        if universalKey != nil, !isControl(data) { return }
        // Control (presencia/alarma/texto/ack): una sola vez por paquete, aunque
        // llegue por los dos canales o rebote; luego se repite al otro canal.
        if forward, isControl(data) {
            guard markSeen(data) else { return }
            if universalKey == nil {
                stateLock.lock(); let hasUniversal = !universalKeys.isEmpty; stateLock.unlock()
                if hasUniversal {
                    universal.send(data)
                    DispatchQueue.main.async { self.relayedPackets += 1 }
                }
            } else {
                let peers = session.connectedPeers
                if !peers.isEmpty {
                    try? session.send(data, toPeers: peers, with: .reliable)
                    DispatchQueue.main.async { self.relayedPackets += 1 }
                }
            }
        }
        guard let msg = VoiceChannel.unwrap(data) else {
            // Sin cabecera de canal: tratar como audio de grupo crudo.
            if payloadLogCount % 50 == 1 { slog.info("payload SIN cabecera VoiceChannel (\(data.count)b) -> play crudo") }
            audio.play(data)
            return
        }
        if payloadLogCount % 50 == 1 { slog.info("payload tipo=\(msg.type.rawValue) audio=\(msg.audio.count)b") }
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
            if let universalKey {
                stateLock.lock(); universalAliases[universalKey] = String(first); stateLock.unlock()
                publishUniversalPeers()
            }
            return
        }
        // Alarma y mensajes recibidos (de iPhone o Android): al log de actividad.
        let myId = Self.idFor(name: localName)
        switch msg.type {
        case .alarm:
            let known = riders.map(\.name) + universalPeers + connectedPeers
            let who = known.first { Self.idFor(name: $0) == msg.targetId }
            addEvent(who.map { "🚨 ALARMA de \($0)" } ?? "🚨 ALARMA recibida")
        case .text:
            guard msg.targetId == 0 || msg.targetId == myId,
                  let text = String(data: msg.audio, encoding: .utf8), !text.isEmpty else { return }
            addEvent((msg.targetId == 0 ? "✉️ Mensaje del grupo: " : "✉️ Mensaje privado: ") + text)
        case .subgroup where msg.isText:
            guard msg.targets.contains(myId),
                  let text = String(data: msg.audio, encoding: .utf8), !text.isEmpty else { return }
            addEvent("✉️ Mensaje de subgrupo: " + text)
        default: break
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
        // Si YA estamos conectados a este peer, IGNORAR la invitación: aceptarla
        // crearía una segunda sesión que mata la activa (el ForceDisconnect en
        // bucle que veíamos, por las reinvitaciones periódicas del iPhone).
        if session.connectedPeers.contains(peerID) {
            addEvent("Ya conectado a \(peerID.displayName), ignoro reinvitación")
            invitationHandler(false, nil)
            return
        }
        if let context, let p = VoiceChannel.parsePickup(context) {
            stateLock.lock(); invitedByAt[peerID] = Date(); stateLock.unlock()
            handlePickup(from: p.sender)
        }
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
        // CRÍTICO: ignorar nuestro propio anuncio. Multipeer a veces se descubre
        // a sí mismo (advertiser + browser juntos); conectarse consigo mismo
        // rompe las sesiones (ForceDisconnect en bucle). Filtrar por displayName.
        guard peerID.displayName != myPeerID.displayName else {
            return
        }
        addEvent("Encontrado \(peerID.displayName)")
        if let uid = info?["uid"] { peerUIDs[peerID] = uid }
        if !foundPeers.contains(peerID) { foundPeers.append(peerID) }
        refreshNearby()

        // Manual: solo queda en la lista; tú eliges con el botón Conectar.
        guard autoConnect else { return }
        guard !session.connectedPeers.contains(peerID) else { return }
        guard !invitedPeers.contains(peerID) else { return }
        guard !recentlyInvitedBy(peerID) else { return }   // él ya me invitó (pickup)
        guard session.connectedPeers.count < Self.maxPeers else { return }
        // Desempate por UID (mismo criterio que el iPhone): invita el UID menor,
        // el otro espera. Sin UID del otro (versión vieja) cae al nombre.
        let iInvite: Bool
        if let otherUID = info?["uid"], !otherUID.isEmpty {
            iInvite = Self.deviceUID < otherUID
        } else {
            iInvite = myPeerID.displayName <= peerID.displayName
        }
        if iInvite {
            invitedPeers.insert(peerID)
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
            addEvent("Invitando a \(peerID.displayName)")
        } else {
            addEvent("Esperando invitación de \(peerID.displayName)")
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        invitedPeers.remove(peerID)
        foundPeers.removeAll { $0 == peerID }
        refreshNearby()
        addEvent("Perdido \(peerID.displayName)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        addEvent("Fallo al buscar: \(error.localizedDescription)")
    }
}
