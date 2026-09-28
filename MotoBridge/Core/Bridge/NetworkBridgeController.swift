import Foundation
import AVFoundation
import Combine
import MultipeerConnectivity
import UserNotifications

/// Une la captura/reproducción de audio (AudioIO) con el transporte de red
/// (PeerBridgeSession). Es el "bridge por red" real: cada dispositivo captura
/// su micrófono y reproduce lo que llega del otro.
///
/// Este es el prototipo de la Alternativa A del FEASIBILITY_REPORT, validado
/// hoy entre iPhone y iPad; en moto, cada teléfono se conectaría a su intercom.
final class NetworkBridgeController: ObservableObject {

    /// Instancia compartida, para que los App Intents (Siri) puedan controlar
    /// el bridge sin depender de la vista SwiftUI.
    static let shared = NetworkBridgeController()

    private(set) var peer = PeerBridgeSession()   // transporte Apple (Multipeer)
    private let audioIO = AudioIO()
    private let audioSession = AVAudioSession.sharedInstance()
    private let watch = WatchBridge()
    private let log = Logger.shared
    private var cancellables = Set<AnyCancellable>()

    /// Transporte activo (según el modo).
    private var transport: AudioTransport

    /// Modo de transporte. No se puede cambiar mientras el bridge corre.
    @Published private(set) var mode: TransportMode = .apple

    @Published private(set) var isRunning = false
    @Published private(set) var isTransmitting = false
    @Published private(set) var packetsSent = 0
    @Published private(set) var packetsReceived = 0

    // Estado genérico del transporte (para la UI, agnóstico del modo).
    @Published private(set) var state: TransportState = .notConnected
    @Published private(set) var discoveredPeers: [TransportPeer] = []
    @Published private(set) var connectedPeers: [TransportPeer] = []
    @Published private(set) var events: [String] = []
    @Published private(set) var localName: String = ""

    /// Nombre del rider (cómo te ven los demás). Se guarda y se aplica antes de
    /// conectar. Cambiarlo solo tiene efecto con el bridge detenido.
    @Published var riderName: String = UserDefaults.standard.string(forKey: "riderName") ?? ""

    /// Ganancia digital del micrófono (1.0–6.0). Sube el volumen de tu voz.
    @Published var micGain: Float = 3.0 {
        didSet { audioIO.captureGain = micGain }
    }

    /// Ganancia de salida (1.0–6.0). Sube el volumen de lo que escuchas,
    /// útil para salidas "bajas" como las Ray-Ban Meta.
    @Published var speakerGain: Float = 1.0 {
        didSet { audioIO.outputGain = speakerGain }
    }

    /// Umbral del noise gate (0.0–0.1). Más alto = corta más ruido de fondo
    /// (música, calle) cuando no hablas. Filtra la voz de la música ambiente.
    @Published var noiseGate: Float = 0.015 {
        didSet { audioIO.gateThreshold = noiseGate }
    }

    /// Compresión Opus. DESACTIVADO por defecto: PCM es 100% estable. Opus
    /// puede crashear si llegan datos no-Opus (desajuste entre dispositivos),
    /// así que se activa manualmente solo cuando ambos lados lo tienen igual.
    @Published var opusEnabled: Bool = false {
        didSet { audioIO.opusEnabled = opusEnabled }
    }

    /// Al conectar un rider, abrir el micrófono automáticamente (modo intercom).
    @Published var autoIntercom: Bool = true

    /// Nombres de riders ya conectados (para notificar solo los nuevos).
    private var knownPeerNames = Set<String>()

    /// Modo llamada (CallKit): trata el bridge como una llamada real para activar
    /// el micrófono HFP de intercoms como el FreedConn. Al activarlo, iOS muestra
    /// la interfaz de llamada. Incompatible con coexistir (la llamada toma el
    /// control del audio). Si se cambia con el bridge activo, se reinicia solo.
    @Published var useCallKit: Bool = false {
        didSet {
            guard oldValue != useCallKit, isRunning else { return }
            // Reiniciar el bridge para aplicar el nuevo modo de audio.
            let wasRunning = isRunning
            stop()
            if wasRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.start()
                }
            }
        }
    }

    /// Modo "coexistir": no interrumpe la música de otras fuentes (CarPlay de la
    /// moto, Spotify, Apple Music). La voz del intercom se suma encima y la
    /// música baja un poco al hablar (ducking). Requiere reiniciar la sesión.
    @Published var coexistWithOtherAudio: Bool = true {
        didSet {
            // Evita reconfigurar cuando el cambio viene de forceBluetoothMic
            // (que ya reconfigura por su cuenta).
            if coexistWithOtherAudioSilent { coexistWithOtherAudioSilent = false; return }
            if isRunning {
                audioQueue.async { [weak self] in
                    self?.configureAudioSession()
                    try? self?.audioIOReconfigure()
                }
            }
        }
    }
    private var coexistWithOtherAudioSilent = false

    /// Nivel de entrada del micrófono (0.0–1.0) para el medidor visual.
    @Published private(set) var inputLevel: Float = 0

    /// Descripción del puerto de entrada activo (para diagnóstico).
    @Published private(set) var inputRoute: String = "—"

    /// Calidad de audio detectada según el dispositivo (AirPods/Beats = alta).
    enum AudioQuality: String { case high = "Alta (AirPods/Beats)", standard = "Estándar", low = "Voz (intercom HFP)" }
    @Published private(set) var detectedQuality: AudioQuality = .standard

    /// Entradas de audio disponibles (AirPods, casco, mic del teléfono…).
    @Published private(set) var availableInputs: [AudioInputOption] = []

    /// UID de la entrada seleccionada actualmente.
    @Published private(set) var selectedInputUID: String?

    /// Una opción de entrada de audio seleccionable.
    struct AudioInputOption: Identifiable, Hashable {
        let id: String        // portUID
        let name: String      // nombre visible
        let type: String      // portType
    }

    init() {
        // Transporte inicial: Apple (Multipeer).
        self.transport = peer
        wireTransport(peer)

        // Nivel de entrada -> medidor visual.
        audioIO.onInputLevel = { [weak self] level in
            DispatchQueue.main.async { self?.inputLevel = level }
        }
        // PTT remoto desde el Apple Watch -> activar/desactivar transmisión.
        watch.onPTTChange = { [weak self] transmitting in
            self?.setTransmitting(transmitting)
        }
        // Audio capturado -> envolver con canal (grupo/privado/alarma) -> enviar.
        audioIO.onCapturedAudio = { [weak self] data in
            guard let self else { return }
            // En alarma, el targetId transporta MI id de nombre para que los
            // demás sepan quién pide ayuda. En privado, el id del destinatario.
            let target = self.channelType == .alarm ? self.myNameId : self.privateTargetId
            let channeled = VoiceChannel.wrap(data, type: self.channelType, targetId: target)
            let toSend = self.meshEnabled ? self.mesh.wrapOutgoing(channeled) : channeled
            self.transport.sendAudio(toSend)
            DispatchQueue.main.async {
                self.packetsSent += 1
                if self.packetsSent % 20 == 1 {
                    self.log.info(.bridge, "TX audio #\(self.packetsSent)")
                }
            }
        }

        // CallKit: el sistema decide cuándo activar/desactivar el audio (así se
        // activa el micrófono HFP del intercom, como en una llamada real).
        CallKitManager.shared.onActivateAudio = { [weak self] in
            self?.audioQueue.async {
                guard let self else { return }
                self.configureAudioSession()
                try? self.audioIO.start()
                self.refreshInputs()
                self.log.info(.audioSession, "Audio arrancado por CallKit")
            }
        }
        CallKitManager.shared.onDeactivateAudio = { [weak self] in
            self?.audioQueue.async { self?.audioIO.stop() }
        }
        CallKitManager.shared.onEndedByUser = { [weak self] in
            DispatchQueue.main.async { self?.stop() }
        }

        // Aplicar calidad por defecto (Opus) y pedir permiso de notificaciones.
        audioIO.opusEnabled = opusEnabled
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private let speech = AVSpeechSynthesizer()
    private var lastAlarmAnnounce = Date.distantPast

    /// Aviso cuando un rider se conecta: por VOZ (se oye en el audífono/intercom,
    /// ideal para moto) y notificación visual de respaldo.
    private func notifyRiderConnected(_ rider: String) {
        // 1) Aviso por voz.
        let utterance = AVSpeechUtterance(string: "\(rider) se conectó")
        utterance.voice = AVSpeechSynthesisVoice(language: "es-MX") ?? AVSpeechSynthesisVoice(language: "es-ES")
        speech.speak(utterance)

        // 2) Notificación visual.
        let content = UNMutableNotificationContent()
        content.title = "Rider conectado"
        content.body = "\(rider) se unió al grupo"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Relay de malla: reenvía audio de otros para extender el alcance.
    private let mesh = MeshRelay()
    /// Activa el reenvío mesh. DESACTIVADO por defecto: solo tiene sentido con
    /// 3+ motos. Con 2 dispositivos (iPad↔iPhone) añade overhead innecesario.
    /// Debe estar IGUAL en todos los dispositivos del grupo.
    @Published var meshEnabled: Bool = false

    // MARK: - Canales de voz (grupo / privado / alarma)

    /// Canal de envío actual.
    @Published private(set) var channelType: VoiceChannelType = .group
    /// Rider con el que hablas en privado (nombre visible).
    @Published private(set) var privatePeerName: String?
    private var privateTargetId: UInt32 = 0

    /// ID estable derivado del nombre del rider (para dirigir el privado sin
    /// depender del originId numérico interno del mesh).
    static func idFor(name: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return hash
    }

    /// Mi id derivado de mi nombre (para que el privado me reconozca).
    private var myNameId: UInt32 { NetworkBridgeController.idFor(name: localName) }

    /// Traduce un id de nombre (FNV-1a) al nombre visible de un rider conectado.
    /// Se usa en la alarma para anunciar quién pide ayuda. Devuelve "" si no se
    /// reconoce (p. ej. el emisor no está en la lista de conectados).
    private func nameForId(_ id: UInt32) -> String {
        if id == 0 { return "" }
        for peer in connectedPeers where NetworkBridgeController.idFor(name: peer.name) == id {
            return peer.name
        }
        return ""
    }

    /// Activa canal privado (susurro) con un rider: tu voz solo le llega a él,
    /// pero tú sigues oyendo al grupo (modo b).
    func startPrivate(with peerName: String) {
        privateTargetId = NetworkBridgeController.idFor(name: peerName)
        privatePeerName = peerName
        channelType = .privateWhisper
        log.info(.bridge, "Canal privado con \(peerName)")
    }

    /// Vuelve al grupo (deja de susurrar).
    func backToGroup() {
        channelType = .group
        privatePeerName = nil
        privateTargetId = 0
        log.info(.bridge, "De vuelta al grupo")
    }

    /// ¿Está transmitiendo una alarma ahora?
    @Published private(set) var alarmActive = false

    /// Envía una ALARMA de emergencia a todo el grupo durante unos segundos:
    /// abre el micrófono, marca el canal como alarma (todos la oyen aunque estén
    /// en privado o con música), y anuncia por voz. Se autolimita a ~6s.
    func sendAlarm() {
        guard isRunning else { return }
        channelType = .alarm
        alarmActive = true
        setTransmitting(true)
        // Aviso local por voz para el que dispara la alarma.
        let u = AVSpeechUtterance(string: "Alarma enviada")
        u.voice = AVSpeechSynthesisVoice(language: "es-MX")
        speech.speak(u)
        log.warning(.bridge, "ALARMA de emergencia enviada")
        // Volver al estado normal tras 6 segundos.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.setTransmitting(false)
            self.alarmActive = false
            self.channelType = self.privatePeerName != nil ? .privateWhisper : .group
        }
    }

    /// Conecta los callbacks de un transporte a las propiedades observables
    /// genéricas y al audio. Se llama al iniciar y al cambiar de modo.
    private func wireTransport(_ t: AudioTransport) {
        localName = t.localName

        t.onAudioData = { [weak self] data in
            guard let self else { return }
            if self.meshEnabled {
                guard let incoming = self.mesh.processIncoming(data) else { return }
                if incoming.isNew {
                    self.playChanneled(incoming.payload)
                }
                if let relay = incoming.relay, self.connectedPeers.count > 1 {
                    self.transport.sendAudio(relay)
                }
            } else {
                self.playChanneled(data)
            }
        }
        t.onStateChange = { [weak self] s in
            DispatchQueue.main.async {
                self?.state = s
                self?.watch.sendStateToWatch(connected: s == .connected)
            }
        }
        t.onPeersChange = { [weak self] discovered, connected in
            DispatchQueue.main.async {
                guard let self else { return }
                let newNames = Set(connected.map { $0.name })
                let added = newNames.subtracting(self.knownPeerNames)
                for rider in added { self.notifyRiderConnected(rider) }
                // Modo intercom: abrir micrófono solo al conectar el primer rider.
                if self.autoIntercom, self.knownPeerNames.isEmpty, !newNames.isEmpty {
                    self.setTransmitting(true)
                }
                self.knownPeerNames = newNames
                self.discoveredPeers = discovered
                self.connectedPeers = connected
            }
        }
        t.onEvent = { [weak self] line in
            DispatchQueue.main.async {
                self?.events.insert(line, at: 0)
                if let count = self?.events.count, count > 12 { self?.events.removeLast() }
            }
        }
    }

    /// Desenvuelve el canal y decide si reproducir según el tipo:
    /// - grupo: siempre.
    /// - privado: solo si soy el destinatario (modo b: sigo oyendo al grupo).
    /// - alarma: siempre, con prioridad (aviso por voz).
    private func playChanneled(_ data: Data) {
        guard let msg = VoiceChannel.unwrap(data) else {
            // Compatibilidad: si no trae cabecera de canal, tratar como grupo.
            audioIO.playReceivedAudio(data)
            return
        }
        switch msg.type {
        case .group:
            audioIO.playReceivedAudio(msg.audio)
        case .privateWhisper:
            // Solo reproducir si el mensaje privado es para mí (por nombre).
            if msg.targetId == myNameId {
                audioIO.playReceivedAudio(msg.audio)
            }
        case .alarm:
            // Emergencia: siempre se reproduce, aunque estés en privado/música.
            audioIO.playReceivedAudio(msg.audio)
            // Anunciar por voz una sola vez por ráfaga de alarma, diciendo QUIÉN
            // pide ayuda (el targetId trae el id de nombre del emisor).
            let now = Date()
            if now.timeIntervalSince(lastAlarmAnnounce) > 4 {
                lastAlarmAnnounce = now
                let who = nameForId(msg.targetId)
                let text = who.isEmpty
                    ? "Emergencia. Un rider necesita ayuda"
                    : "Emergencia. \(who) necesita ayuda"
                let u = AVSpeechUtterance(string: text)
                u.voice = AVSpeechSynthesisVoice(language: "es-MX")
                DispatchQueue.main.async { self.speech.speak(u) }
            }
        }
        DispatchQueue.main.async { self.packetsReceived += 1 }
    }

    /// Cambia el modo de transporte. Solo permitido con el bridge detenido.
    func setMode(_ newMode: TransportMode) {
        guard !isRunning, newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .apple:
            transport = peer
        case .universal:
            transport = LocalNetworkTransport()
        }
        wireTransport(transport)
        // Reset de estado visible.
        state = .notConnected
        discoveredPeers = []
        connectedPeers = []
        events = []
        log.info(.bridge, "Modo de transporte: \(newMode.rawValue)")
    }

    // MARK: - Control

    /// Cola de fondo para operaciones de audio (evita bloquear el hilo principal,
    /// que provoca el "AVAudioSession Hang Risk").
    private let audioQueue = DispatchQueue(label: "com.motobridge.audio", qos: .userInitiated)

    /// Configura la sesión de audio, arranca captura/reproducción y descubrimiento.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // El descubrimiento de red arranca de inmediato (barato y seguro en main).
        transport.start()
        log.info(.bridge, "NetworkBridge iniciado (\(mode.rawValue))")

        // Modo CallKit: el audio lo arranca el sistema en onActivateAudio.
        // El micrófono HFP del intercom se activa como en una llamada real.
        if useCallKit {
            // CallKit no coexiste con otra música: toma control del audio.
            coexistWithOtherAudioSilent = true
            DispatchQueue.main.async { self.coexistWithOtherAudio = false }
            CallKitManager.shared.startCall(peerName: connectedPeers.first?.name ?? "MotoBridge")
            return
        }

        // El audio se configura en background para no colgar la UI.
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.configureAudioSession()
            do {
                try self.audioIO.start()
                self.log.info(.audioSession, "AudioIO iniciado")
                self.refreshInputs()
            } catch {
                self.log.error(.audioSession, "No se pudo iniciar AudioIO: \(error.localizedDescription)")
            }
        }
    }

    /// Refresca la lista de entradas disponibles y la entrada activa.
    func refreshInputs() {
        let inputs = audioSession.availableInputs ?? []
        let options = inputs.map {
            AudioInputOption(id: $0.uid, name: $0.portName, type: $0.portType.rawValue)
        }
        let route = audioSession.currentRoute
        let activeUID = route.inputs.first?.uid
        let ins = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")

        // Detectar calidad según el dispositivo (por nombre y perfil).
        let allNames = (route.inputs + route.outputs).map { $0.portName.lowercased() }
        let isHighEnd = allNames.contains { $0.contains("airpod") || $0.contains("beats") }
        let isA2DP = route.outputs.contains { $0.portType == .bluetoothA2DP }
        let quality: AudioQuality = (isHighEnd || isA2DP) ? .high : (route.inputs.contains { $0.portType == .bluetoothHFP } ? .low : .standard)

        // Ajuste adaptativo del procesamiento según el dispositivo:
        // - AirPods/Beats: su hardware ya cancela ruido → filtrado suave y SIN
        //   realce agresivo (suena más natural y limpio).
        // - Intercom HFP barato: filtrado y realce más fuertes.
        switch quality {
        case .high:
            audioIO.gateThreshold = 0.006
            audioIO.voiceEnhancementEnabled = false // dejar que el hardware bueno mande
        case .standard:
            audioIO.gateThreshold = 0.012
            audioIO.voiceEnhancementEnabled = true
        case .low:
            audioIO.gateThreshold = 0.018
            audioIO.voiceEnhancementEnabled = true
        }

        DispatchQueue.main.async {
            self.availableInputs = options
            self.selectedInputUID = activeUID
            self.inputRoute = ins.isEmpty ? "sin entrada" : ins
            self.detectedQuality = quality
        }
    }

    /// Selecciona una entrada preferida (AirPods, intercom, mic del teléfono).
    /// Fija el puerto preferido SIN reiniciar el motor completo (eso rompía la
    /// conexión); iOS aplica el cambio de entrada en caliente. El engine capta
    /// el nuevo formato en el siguiente route-change automáticamente.
    func selectInput(_ option: AudioInputOption) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard let port = (self.audioSession.availableInputs ?? []).first(where: { $0.uid == option.id }) else {
                self.log.warning(.audioRoute, "Entrada no encontrada: \(option.name)")
                DispatchQueue.main.async { self.refreshInputs() }
                return
            }
            do {
                try self.audioSession.setPreferredInput(port)
                self.log.info(.audioRoute, "Entrada preferida: \(option.name) (\(option.type))")
            } catch {
                self.log.error(.audioRoute, "No se pudo fijar entrada \(option.name): \(error.localizedDescription)")
            }
            // Pequeña espera y refrescar la UI con la ruta ya aplicada.
            self.audioQueue.asyncAfter(deadline: .now() + 0.2) {
                self.refreshInputs()
            }
        }
    }

    /// Selecciona la SALIDA de audio (dónde escuchas): altavoz, o el dispositivo
    /// Bluetooth conectado (AirPods/intercom). iOS enruta la salida a la ruta
    /// preferida disponible.
    func selectOutputSpeaker(_ toSpeaker: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.audioSession.overrideOutputAudioPort(toSpeaker ? .speaker : .none)
                self.log.info(.audioRoute, "Salida: \(toSpeaker ? "altavoz" : "dispositivo BT/auto")")
            } catch {
                self.log.error(.audioRoute, "No se pudo cambiar salida: \(error.localizedDescription)")
            }
            self.audioQueue.asyncAfter(deadline: .now() + 0.2) { self.refreshInputs() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        setTransmitting(false)
        knownPeerNames.removeAll()
        transport.stop()
        if useCallKit {
            CallKitManager.shared.endCall()
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.audioIO.stop()
            self.deactivateAudioSession()
        }
        log.info(.bridge, "NetworkBridge detenido")
    }

    /// Reinicia el motor de audio (tras cambiar la configuración de sesión).
    private func audioIOReconfigure() throws {
        try audioIO.restart()
    }

    /// Push-to-talk: solo se transmite mientras esté activo.
    func setTransmitting(_ transmitting: Bool) {
        audioIO.isTransmitting = transmitting
        DispatchQueue.main.async { self.isTransmitting = transmitting }
        log.debug(.bridge, "PTT \(transmitting ? "ON" : "OFF")")
    }

    /// Guarda el nombre del rider y recrea el transporte para aplicarlo.
    /// Solo con el bridge detenido.
    func applyRiderName(_ name: String) {
        let clean = String(name.prefix(30)).trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(clean, forKey: "riderName")
        riderName = clean
        guard !isRunning else { return }
        // Recrear los transportes para que tomen el nombre nuevo.
        peer = PeerBridgeSession()
        if mode == .apple { transport = peer }
        else { transport = LocalNetworkTransport() }
        wireTransport(transport)
        log.info(.bridge, "Nombre de rider: \(clean.isEmpty ? "(dispositivo)" : clean)")
    }

    /// Prepara/lista las rutas de audio SIN iniciar el bridge, para elegir
    /// audífono/intercom antes de conectar. Activa la sesión brevemente para
    /// que iOS exponga los dispositivos Bluetooth disponibles.
    func prepareAudioRoutes() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let opt: AVAudioSession.CategoryOptions
                if #available(iOS 18.0, *) { opt = .allowBluetoothHFP } else { opt = AVAudioSession.CategoryOptions(rawValue: 0x4) }
                try self.audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [opt])
                try self.audioSession.setActive(true)
            } catch {
                self.log.error(.audioRoute, "prepareAudioRoutes: \(error.localizedDescription)")
            }
            self.refreshInputs()
        }
    }

    /// Cierra el bridge, libera el audio y termina la app para no consumir
    /// batería en segundo plano.
    func shutdownAndExit() {
        stop()
        audioQueue.async { [weak self] in
            self?.audioIO.stop()
            self?.deactivateAudioSession()
            // Dar un instante a que se liberen recursos y salir limpiamente.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exit(0)
            }
        }
    }

    // MARK: - Acciones para comandos de voz (App Intents / Siri)

    /// Arranca o detiene el bridge (comando de voz).
    func toggleBridge() {
        if isRunning { stop() } else { start() }
    }

    /// Micrófono abierto (transmitir continuo) on/off por voz.
    func setMicOpen(_ open: Bool) {
        setTransmitting(open)
    }

    /// Sube el volumen de escucha un paso (tope 6.0).
    func volumeUp() {
        DispatchQueue.main.async { self.speakerGain = min(6.0, self.speakerGain + 1.0) }
    }

    /// Baja el volumen de escucha un paso (mínimo 1.0).
    func volumeDown() {
        DispatchQueue.main.async { self.speakerGain = max(1.0, self.speakerGain - 1.0) }
    }

    /// Fuerza el modo "llamada" y selecciona el puerto Bluetooth HFP como
    /// entrada. Esto activa el micrófono de intercoms (como el FreedConn) que
    /// solo lo habilitan en contexto de llamada. Desactiva coexistir porque
    /// mezclar audio impide que iOS abra bien el canal HFP.
    func forceBluetoothMic() {
        // Coexistir OFF en main (sin sync desde la cola de audio → evita bloqueos
        // y el rebote de ruta que causaba conectar/desconectar).
        coexistWithOtherAudioSilent = false
        DispatchQueue.main.async { self.coexistWithOtherAudio = false }
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.configureAudioSession()

            // Buscar un puerto de entrada Bluetooth HFP y fijarlo.
            let inputs = self.audioSession.availableInputs ?? []
            if let hfp = inputs.first(where: { $0.portType == .bluetoothHFP }) {
                do {
                    try self.audioSession.setPreferredInput(hfp)
                    self.log.info(.audioRoute, "Forzado micrófono HFP: \(hfp.portName)")
                } catch {
                    self.log.error(.audioRoute, "No se pudo forzar HFP: \(error.localizedDescription)")
                }
            } else {
                self.log.warning(.audioRoute, "No hay puerto Bluetooth HFP disponible. ¿El intercom está en modo teléfono?")
            }
            try? self.audioIO.restart()
            self.refreshInputs()
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        do {
            let bluetoothOption: AVAudioSession.CategoryOptions
            if #available(iOS 18.0, *) {
                bluetoothOption = .allowBluetoothHFP
            } else {
                bluetoothOption = AVAudioSession.CategoryOptions(rawValue: 0x4)
            }
            // IMPORTANTE: NO usamos .allowBluetoothA2DP aquí. A2DP da salida
            // estéreo de alta calidad pero NO tiene micrófono. Para un intercom
            // bidireccional necesitamos HFP (mono, con micrófono + altavoz).
            var options: AVAudioSession.CategoryOptions = [bluetoothOption]

            if coexistWithOtherAudio {
                // Modo Coexistir: NO interrumpe la música de CarPlay/Spotify/etc.
                // La voz se suma encima; la música baja un poco al hablar (duck).
                options.insert(.mixWithOthers)
                options.insert(.duckOthers)
            }

            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: options
            )
            try audioSession.setActive(true, options: [])
            log.info(.audioSession, "AudioSession lista (coexistir=\(coexistWithOtherAudio))")
        } catch {
            log.error(.audioSession, "Error configurando AudioSession: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log.error(.audioSession, "Error desactivando AudioSession: \(error.localizedDescription)")
        }
    }
}
