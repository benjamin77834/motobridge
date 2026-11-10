import Foundation
import Network

/// Canal "Universal" para macOS (Mac ↔ Android/iPhone por red local).
///
/// Adaptación de MotoBridge/Core/Network/LocalNetworkTransport.swift (iOS) a la
/// Mac: UDP + Bonjour `_motobridge._udp` con Network.framework, según PROTOCOL.md.
/// Corre en paralelo con el canal Multipeer ("mbapple") de RelaySession.
///
/// Regla de conexión (igual que Android/iOS): el nombre "menor" inicia. Como
/// Android también manda a todo peer que resuelve por NSD, la Mac recibe tráfico
/// aunque sea el nombre "mayor".
///
/// Este transporte solo mueve datagramas: cada datagrama lleva la cabecera de
/// 4 bytes de PROTOCOL.md §4 y, como hace iOS, dentro viaja el paquete
/// VoiceChannel (presencia, alarma, texto, ack, audio).
final class UniversalTransport {

    static let serviceType = "_motobridge._udp"
    static let serviceDomain = "local."
    static let maxPeers = 7

    let localName: String

    /// (paquete VoiceChannel/malla sin la cabecera de 4 bytes, clave del peer).
    /// Se invoca en la cola interna del transporte.
    var onPacket: ((Data, String) -> Void)?
    /// Claves de peers activos (cambia al conectar/perder).
    var onPeersChange: (([String]) -> Void)?
    var onEvent: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.motobridge.relay.universal")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var ready = Set<String>()
    private var lastRx: [String: Date] = [:]
    private var lastResults: Set<NWBrowser.Result> = []
    private var pruneTimer: DispatchSourceTimer?
    private var isRunning = false

    init(localName: String) { self.localName = localName }

    // MARK: Control

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            startListener()
            startBrowser()
            startPruneTimer()
            emit("Universal: publicando y buscando en red local")
        }
    }

    func stop() {
        queue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            listener?.cancel(); listener = nil
            browser?.cancel(); browser = nil
            pruneTimer?.cancel(); pruneTimer = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll(); ready.removeAll(); lastRx.removeAll(); lastResults = []
            notifyPeers()
            emit("Universal: detenido")
        }
    }

    /// Envía un paquete (VoiceChannel) a las claves indicadas, o a todas si nil.
    func send(_ payload: Data, toKeys keys: [String]? = nil) {
        queue.async { [self] in
            var framed = Data([0x4D, 0x01, 0x01, 0x00])   // 'M', v1, audio, reservado
            framed.append(payload)
            for (key, conn) in connections where ready.contains(key) && (keys?.contains(key) ?? true) {
                conn.send(content: framed, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: Listener

    private func startListener() {
        do {
            let params = NWParameters.udp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: localName, type: Self.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state { self?.emit("Universal: listener falló: \(err.localizedDescription)") }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.adopt(connection: conn, key: "in-\(conn.endpoint)")
            }
            l.start(queue: queue)
            listener = l
        } catch {
            emit("Universal: no se pudo crear listener: \(error.localizedDescription)")
        }
    }

    // MARK: Browser

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: Self.serviceDomain), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.lastResults = results
            self.evaluate(results)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { self?.emit("Universal: browser falló: \(err.localizedDescription)") }
        }
        b.start(queue: queue)
        browser = b
    }

    /// Conecta a los servicios cuyo nombre es "mayor" que el mío (yo inicio).
    private func evaluate(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name != localName else { continue }
            if connections[name] != nil { continue }
            if connections.count >= Self.maxPeers { break }
            if localName < name {
                emit("Universal: conectando a \(name)…")
                let params = NWParameters.udp
                params.includePeerToPeer = true
                adopt(connection: NWConnection(to: result.endpoint, using: params), key: name)
            }
        }
    }

    // MARK: Conexiones

    private func adopt(connection conn: NWConnection, key: String) {
        if connections.count >= Self.maxPeers, connections[key] == nil { conn.cancel(); return }
        connections[key]?.cancel()
        connections[key] = conn
        lastRx[key] = Date()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            // Ignorar eventos de una conexión que ya fue reemplazada.
            guard self.connections[key] === conn else { return }
            switch state {
            case .ready:
                self.ready.insert(key)
                self.notifyPeers()
                self.receive(on: conn, key: key)
            case .failed, .cancelled:
                self.remove(key)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func remove(_ key: String) {
        connections[key]?.cancel()
        connections[key] = nil
        ready.remove(key); lastRx[key] = nil
        notifyPeers()
    }

    private func receive(on conn: NWConnection, key: String) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connections[key] === conn else { return }
            if let data {
                self.lastRx[key] = Date()
                // PROTOCOL.md §4: magic 'M', tipo 0x01, payload tras 4 bytes.
                if data.count > 4, data[data.startIndex] == 0x4D, data[data.startIndex + 2] == 0x01 {
                    self.onPacket?(data.subdata(in: (data.startIndex + 4)..<data.endIndex), key)
                }
            }
            if error == nil { self.receive(on: conn, key: key) } else { self.remove(key) }
        }
    }

    /// Quita peers sin tráfico en 30 s (UDP no avisa) y reintenta los que yo inicio.
    private func startPruneTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for (key, last) in self.lastRx where now.timeIntervalSince(last) > 30 { self.remove(key) }
            self.evaluate(self.lastResults)
        }
        t.resume()
        pruneTimer = t
    }

    private func notifyPeers() {
        let keys = connections.keys.filter { ready.contains($0) }.sorted()
        onPeersChange?(keys)
    }

    private func emit(_ text: String) { onEvent?(text) }
}
