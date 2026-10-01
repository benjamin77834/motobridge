import Foundation
import AVFoundation
import Combine
import MediaPlayer
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
    /// Activado por defecto: en modo llamada, iOS deja que Siri conviva con el
    /// bridge (como en una llamada telefónica real), así los comandos de voz
    /// siguen funcionando mientras estás conectado. Se persiste la preferencia.
    @Published var useCallKit: Bool = (UserDefaults.standard.object(forKey: "useCallKit") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(useCallKit, forKey: "useCallKit")
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

    /// Modo "Música + intercom automático": cuando NADIE habla, suelta el
    /// micrófono y deja la sesión en modo música (A2DP estéreo por CarPlay/
    /// bocinas). Al hablar tú o llegar voz de otro rider, cambia a modo voz
    /// (HFP + micrófono) y la música baja (duck); al cesar la voz vuelve solo a
    /// música. Pensado para escuchar Spotify/CarPlay en la moto sin perder el
    /// intercom. Incompatible con CallKit (que corta la música).
    @Published var autoMusicMode: Bool = (UserDefaults.standard.object(forKey: "autoMusicMode") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(autoMusicMode, forKey: "autoMusicMode")
            guard oldValue != autoMusicMode else { return }
            if autoMusicMode {
                // Incompatible con modo llamada: se desactiva para que la música suene.
                if useCallKit { useCallKit = false }
                coexistWithOtherAudio = true
            }
            if isRunning {
                let wasRunning = isRunning
                stop()
                if wasRunning {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
                }
            }
        }
    }

    /// Destino de salida elegido manualmente por el rider.
    ///  - headset: cascos / intercom (HFP, con micrófono para hablar).
    ///  - speakers: bocinas de la moto / CarPlay (A2DP estéreo, sin micrófono).
    /// Es el switch "Cascos ↔ Bocinas". No aplica en modo automático.
    enum OutputTarget: String { case headset, speakers }
    @Published private(set) var outputTarget: OutputTarget =
        OutputTarget(rawValue: UserDefaults.standard.string(forKey: "outputTarget") ?? "") ?? .headset

    /// Cambia el destino de salida (switch manual Cascos ↔ Bocinas).
    /// En bocinas: música por CarPlay/A2DP y se suelta el micrófono.
    /// En cascos: intercom por HFP con micrófono abierto para hablar.
    func setOutput(_ target: OutputTarget) {
        guard outputTarget != target else { return }
        outputTarget = target
        UserDefaults.standard.set(target.rawValue, forKey: "outputTarget")
        log.info(.audioRoute, "Salida elegida: \(target.rawValue)")
        guard isRunning, !autoMusicMode else { return }
        audioQueue.async { [weak self] in
            guard let self else { return }
            switch target {
            case .speakers:
                // Modo música: A2DP estéreo. iOS enruta a CarPlay si está
                // conectado (es la salida A2DP/HDMI del vehículo).
                self.configureSessionForMusic()
                self.audioIO.stop()   // libera mic → música por bocinas/CarPlay
                self.routeToCarPlayIfAvailable()
            case .headset:
                // Modo intercom: HFP con el audífono/Hysnox como entrada+salida.
                self.configureAudioSession()
                self.forcePreferredHFPInput()
                try? self.audioIO.start()
                self.refreshInputs()
            }
            self.logCurrentRoute()
        }
    }

    /// Fija el puerto Bluetooth HFP (audífono / Hysnox) como entrada preferida,
    /// para que el intercom use ese micrófono y altavoz.
    private func forcePreferredHFPInput() {
        let inputs = audioSession.availableInputs ?? []
        if let hfp = inputs.first(where: { $0.portType == .bluetoothHFP }) {
            do {
                try audioSession.setPreferredInput(hfp)
                log.info(.audioRoute, "Cascos: entrada HFP fijada → \(hfp.portName)")
            } catch {
                log.warning(.audioRoute, "No se pudo fijar HFP: \(error.localizedDescription)")
            }
        } else {
            log.warning(.audioRoute, "Cascos: no hay puerto HFP (¿intercom en modo teléfono?)")
        }
    }

    /// En modo música, si hay CarPlay conectado, se prefiere esa salida. iOS ya
    /// enruta A2DP/CarPlay automáticamente; aquí solo lo registramos y quitamos
    /// cualquier override a altavoz que hubiéramos puesto antes.
    private func routeToCarPlayIfAvailable() {
        do { try audioSession.overrideOutputAudioPort(.none) } catch {
            log.warning(.audioRoute, "override .none falló: \(error.localizedDescription)")
        }
        let outs = audioSession.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        let hasCarPlay = audioSession.currentRoute.outputs.contains { $0.portType == .carAudio }
        log.info(.audioRoute, "Bocinas: salida actual = \(outs.joined(separator: ", ")); CarPlay=\(hasCarPlay)")
    }

    /// Registra la ruta de audio activa (diagnóstico del switch de salida).
    private func logCurrentRoute() {
        let route = audioSession.currentRoute
        let ins = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        log.info(.audioRoute, "Ruta activa → in:[\(ins)] out:[\(outs)]")
    }

    /// Alterna entre cascos y bocinas (para el botón del intercom / switch).
    func toggleOutput() {
        setOutput(outputTarget == .headset ? .speakers : .headset)
    }

    // MARK: - Control de música del sistema (Spotify / Apple Music)

    /// ¿Está sonando música del reproductor del sistema? (para el icono play/pausa)
    @Published private(set) var musicPlaying: Bool = false

    /// Reproductor del sistema: controla la música de Apple Music / Spotify que
    /// ya esté cargada, sin tener que abrir esa app.
    private let systemPlayer = MPMusicPlayerController.systemMusicPlayer

    /// Play/Pausa de la música del sistema. Así el rider no tiene que salir de
    /// Mono Bridge para pausar o reanudar Spotify/Apple Music.
    /// Pide autorización primero: sin ella, iOS aborta la app al tocar el player.
    func toggleMusic() {
        let status = MPMediaLibrary.authorizationStatus()
        switch status {
        case .authorized:
            performToggleMusic()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized { self?.performToggleMusic() }
                    else { self?.log.warning(.bridge, "Música: permiso denegado") }
                }
            }
        default:
            log.warning(.bridge, "Música: sin permiso para controlar la reproducción")
        }
    }

    private func performToggleMusic() {
        if systemPlayer.playbackState == .playing {
            systemPlayer.pause()
            musicPlaying = false
            log.info(.bridge, "Música: pausa")
        } else {
            systemPlayer.play()
            musicPlaying = true
            log.info(.bridge, "Música: play")
        }
    }

    /// Sincroniza el estado visible del botón con el reproductor real.
    /// Solo consulta si ya hay permiso (evita abortar la app sin autorización).
    func refreshMusicState() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        musicPlaying = systemPlayer.playbackState == .playing
    }

    /// Estado interno del conmutador música/voz.
    private enum AudioFocus { case music, voice }
    private var audioFocus: AudioFocus = .music
    /// Última vez que hubo voz (mi mic abierto o audio entrante de un rider).
    private var lastVoiceActivity = Date.distantPast
    /// Segundos de silencio antes de volver a música full.
    private let voiceHangoverSeconds: TimeInterval = 1.5
    private var focusTimer: Timer?

    /// Nivel de entrada del micrófono (0.0–1.0) para el medidor visual.
    @Published private(set) var inputLevel: Float = 0

    /// Descripción del puerto de entrada activo (para diagnóstico).
    @Published private(set) var inputRoute: String = "—"

    /// Calidad de audio detectada según el dispositivo (AirPods/Beats = alta).
    enum AudioQuality: String { case high = "Alta (AirPods/Beats)", standard = "Estándar", low = "Voz (intercom HFP)" }
    @Published private(set) var detectedQuality: AudioQuality = .standard

    /// ¿Se detectaron unas Ray-Ban Meta como salida? (volumen bajo → sube ganancia).
    @Published private(set) var rayBanDetected = false
    /// Para subir la ganancia una sola vez al detectarlas (no pisar ajustes del usuario después).
    private var rayBanAutoBoosted = false

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
            let channeled: Data
            if self.channelType == .subgroup, !self.activeSubgroupTargets.isEmpty {
                // Voz dirigida a un subgrupo de riders elegidos.
                channeled = VoiceChannel.wrapSubgroup(data, targets: self.activeSubgroupTargets, isText: false)
            } else {
                let target = self.channelType == .alarm ? self.myNameId : self.privateTargetId
                channeled = VoiceChannel.wrap(data, type: self.channelType, targetId: target)
            }
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

        // Botones del intercom (Hysnox) → acciones del bridge.
        // Botón central (play/pause): hablar (PTT toggle).
        remoteControl.onTogglePressed = { [weak self] in
            guard let self, self.isRunning else { return }
            DispatchQueue.main.async { self.setTransmitting(!self.isTransmitting) }
        }
        // Siguiente (▶▶): salida a las bocinas de la moto.
        remoteControl.onNextPressed = { [weak self] in
            DispatchQueue.main.async { self?.setOutput(.speakers) }
        }
        // Anterior (◀◀): salida a los cascos / intercom.
        remoteControl.onPreviousPressed = { [weak self] in
            DispatchQueue.main.async { self?.setOutput(.headset) }
        }

        // Aplicar calidad por defecto (Opus) y pedir permiso de notificaciones.
        // Se omite la petición al capturar screenshots para las tiendas (evita
        // que el diálogo del sistema tape la pantalla).
        audioIO.opusEnabled = opusEnabled
        let skipPrompts = ProcessInfo.processInfo.environment["MB_SCREENSHOTS"] != nil
            || CommandLine.arguments.contains("-MBScreenshots")
        if !skipPrompts {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Lee los botones del intercom (Hysnox) vía control remoto multimedia.
    private let remoteControl = RemoteControlManager()

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

    // MARK: - Radar de riders (LED por saltos)

    /// Estado de señal de un rider para el "radar": color según cercanía.
    struct RiderSignal: Identifiable {
        var id: String { name }
        let name: String
        var hops: Int          // saltos (0 = directo/cerca)
        var lastSeen: Date     // último latido/voz recibido
        /// Color del LED: verde (cerca), amarillo (lejos), rojo (perdido).
        enum Level { case near, far, lost }
        var level: Level {
            let age = Date().timeIntervalSince(lastSeen)
            if age > 7 { return .lost }
            return hops <= 1 ? .near : .far
        }
    }
    @Published private(set) var riderSignals: [RiderSignal] = []
    private var presenceTimer: Timer?

    /// Registra que se oyó a un rider (por latido o voz) y actualiza su LED.
    private func noteRiderSeen(_ name: String, hops: Int) {
        log.info(.bridge, "RADAR: latido de \"\(name)\" (yo soy \"\(localName)\"), hops=\(hops)")
        guard name != localName else { return }  // no me cuento a mí
        DispatchQueue.main.async {
            if let idx = self.riderSignals.firstIndex(where: { $0.name == name }) {
                self.riderSignals[idx].hops = hops
                self.riderSignals[idx].lastSeen = Date()
            } else {
                self.riderSignals.append(RiderSignal(name: name, hops: hops, lastSeen: Date()))
            }
        }
    }

    /// Emite un latido de presencia (nombre) para que el radar de los demás nos vea.
    private func sendPresence() {
        guard isRunning, !localName.isEmpty, let payload = localName.data(using: .utf8) else { return }
        let channeled = VoiceChannel.wrap(payload, type: .presence, targetId: 0)
        let toSend = meshEnabled ? mesh.wrapOutgoing(channeled) : channeled
        transport.sendAudio(toSend)
    }

    /// Arranca el latido periódico y la limpieza del radar.
    private func startPresenceTimer() {
        presenceTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.sendPresence()
            // Refrescar la vista (para que los LED cambien a rojo al expirar).
            DispatchQueue.main.async { self.riderSignals = self.riderSignals }
        }
        RunLoop.main.add(t, forMode: .common)
        presenceTimer = t
    }
    private func stopPresenceTimer() {
        presenceTimer?.invalidate(); presenceTimer = nil
        DispatchQueue.main.async { self.riderSignals = [] }
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

    // MARK: - Subgrupos (varios riders elegidos)

    /// Un subgrupo con nombre y la lista de riders que lo forman.
    struct Subgroup: Identifiable, Codable, Hashable {
        var id: String { name }
        var name: String
        var members: [String]   // nombres de riders
    }

    /// Subgrupos guardados por el usuario (persisten).
    @Published private(set) var subgroups: [Subgroup] = NetworkBridgeController.loadSubgroups()
    /// Subgrupo activo para hablar por voz (nil = no dirigido a subgrupo).
    @Published private(set) var activeSubgroupName: String?
    /// nameIds de los miembros del subgrupo activo (para envоlver el audio).
    private var activeSubgroupTargets: [UInt32] = []

    private static func loadSubgroups() -> [Subgroup] {
        guard let data = UserDefaults.standard.data(forKey: "subgroups"),
              let list = try? JSONDecoder().decode([Subgroup].self, from: data) else { return [] }
        return list
    }
    private func saveSubgroups() {
        if let data = try? JSONEncoder().encode(subgroups) {
            UserDefaults.standard.set(data, forKey: "subgroups")
        }
    }

    /// Crea o actualiza un subgrupo.
    func saveSubgroup(name: String, members: [String]) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !members.isEmpty else { return }
        if let idx = subgroups.firstIndex(where: { $0.name == clean }) {
            subgroups[idx].members = members
        } else {
            subgroups.append(Subgroup(name: clean, members: members))
        }
        saveSubgroups()
        log.info(.bridge, "Subgrupo guardado: \(clean) (\(members.count) riders)")
    }

    /// Elimina un subgrupo.
    func deleteSubgroup(name: String) {
        subgroups.removeAll { $0.name == name }
        if activeSubgroupName == name { backToGroup() }
        saveSubgroups()
    }

    /// Activa hablar por voz hacia un subgrupo: tu voz solo llega a esos riders.
    func startSubgroup(_ name: String) {
        guard let sg = subgroups.first(where: { $0.name == name }) else { return }
        activeSubgroupTargets = sg.members.map { NetworkBridgeController.idFor(name: $0) }
        activeSubgroupName = name
        privatePeerName = nil
        privateTargetId = 0
        channelType = .subgroup
        log.info(.bridge, "Hablando al subgrupo \(name): \(sg.members.joined(separator: ", "))")
    }

    /// Activa canal privado (susurro) con un rider: tu voz solo le llega a él,
    /// pero tú sigues oyendo al grupo (modo b).
    func startPrivate(with peerName: String) {
        privateTargetId = NetworkBridgeController.idFor(name: peerName)
        privatePeerName = peerName
        activeSubgroupName = nil
        activeSubgroupTargets = []
        channelType = .privateWhisper
        log.info(.bridge, "Canal privado con \(peerName)")
    }

    /// Vuelve al grupo (deja de susurrar / de hablar al subgrupo).
    func backToGroup() {
        channelType = .group
        privatePeerName = nil
        privateTargetId = 0
        activeSubgroupName = nil
        activeSubgroupTargets = []
        log.info(.bridge, "De vuelta al grupo")
    }

    /// Envía un mensaje de texto a un subgrupo (todos sus miembros lo leen por voz).
    func sendTextToSubgroup(_ text: String, subgroup name: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !clean.isEmpty,
              let sg = subgroups.first(where: { $0.name == name }),
              let payload = clean.data(using: .utf8) else { return }
        let targets = sg.members.map { NetworkBridgeController.idFor(name: $0) }
        let channeled = VoiceChannel.wrapSubgroup(payload, targets: targets, isText: true)
        let toSend = meshEnabled ? mesh.wrapOutgoing(channeled) : channeled
        transport.sendAudio(toSend)
        let u = AVSpeechUtterance(string: "Mensaje enviado al grupo \(name)")
        u.voice = AVSpeechSynthesisVoice(language: "es-MX")
        DispatchQueue.main.async { self.speech.speak(u) }
        log.info(.bridge, "Texto a subgrupo \(name): \(clean)")
    }

    /// Envía un mensaje ESCRITO que el receptor leerá por voz (TTS) en su casco.
    ///  - text: el texto a leer.
    ///  - privateTo: nombre del rider destinatario; nil = a todo el grupo.
    /// Viaja por el transporte igual que el audio, con cabecera de canal texto.
    func sendTextMessage(_ text: String, privateTo peerName: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !clean.isEmpty else { return }
        let target = peerName != nil ? NetworkBridgeController.idFor(name: peerName!) : 0
        guard let payload = clean.data(using: .utf8) else { return }
        let channeled = VoiceChannel.wrap(payload, type: .text, targetId: target)
        let toSend = meshEnabled ? mesh.wrapOutgoing(channeled) : channeled
        transport.sendAudio(toSend)
        // Confirmación local por voz de que se envió.
        let who = peerName != nil ? "a \(peerName!)" : "al grupo"
        let u = AVSpeechUtterance(string: "Mensaje enviado \(who)")
        u.voice = AVSpeechSynthesisVoice(language: "es-MX")
        DispatchQueue.main.async { self.speech.speak(u) }
        log.info(.bridge, "Mensaje de texto enviado (\(who)): \(clean)")
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
                    self.playChanneled(incoming.payload, hops: incoming.hops)
                }
                if let relay = incoming.relay, self.connectedPeers.count > 1 {
                    self.transport.sendAudio(relay)
                }
            } else {
                self.playChanneled(data, hops: 0)   // sin mesh = conexión directa
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
                // Radar: sembrar con los peers conectados (verde) aunque el
                // latido de presencia aún no llegue. El presence refina los saltos.
                for peer in connected { self.noteRiderSeen(peer.name, hops: 0) }
                // Quitar del radar los que ya no están conectados.
                self.riderSignals.removeAll { sig in !newNames.contains(sig.name) }
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
    private func playChanneled(_ data: Data, hops: Int = 0) {
        guard let msg = VoiceChannel.unwrap(data) else {
            // Compatibilidad: si no trae cabecera de canal, tratar como grupo.
            audioIO.playReceivedAudio(data)
            return
        }
        switch msg.type {
        case .presence:
            // Latido de otro rider para el radar. El payload es su nombre.
            if let name = String(data: msg.audio, encoding: .utf8), !name.isEmpty {
                noteRiderSeen(name, hops: hops)
            }
            return
        case .group:
            noteVoiceActivity()
            audioIO.playReceivedAudio(msg.audio)
        case .privateWhisper:
            // Solo reproducir si el mensaje privado es para mí (por nombre).
            if msg.targetId == myNameId {
                noteVoiceActivity()
                audioIO.playReceivedAudio(msg.audio)
            }
        case .alarm:
            noteVoiceActivity()
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
        case .text:
            // Mensaje escrito: si es privado (targetId != 0) solo lo leo si es
            // para mí; si es 0, es para todo el grupo. Se lee por voz (TTS).
            if msg.targetId != 0, msg.targetId != myNameId { break }
            guard let text = String(data: msg.audio, encoding: .utf8), !text.isEmpty else { break }
            let who = nameForId(msg.targetId)   // "" si es al grupo
            let prefix = msg.targetId == 0 ? "Mensaje del grupo. " : "Mensaje privado. "
            let u = AVSpeechUtterance(string: prefix + text)
            u.voice = AVSpeechSynthesisVoice(language: "es-MX")
            DispatchQueue.main.async { self.speech.speak(u) }
            log.info(.bridge, "Mensaje de texto recibido (de \(who.isEmpty ? "grupo" : who)): \(text)")
        case .subgroup:
            // Subgrupo: solo proceso si mi nameId está en la lista de destinatarios.
            guard msg.targets.contains(myNameId) else { break }
            if msg.isText {
                guard let text = String(data: msg.audio, encoding: .utf8), !text.isEmpty else { break }
                let u = AVSpeechUtterance(string: "Mensaje de grupo privado. " + text)
                u.voice = AVSpeechSynthesisVoice(language: "es-MX")
                DispatchQueue.main.async { self.speech.speak(u) }
                log.info(.bridge, "Texto de subgrupo recibido: \(text)")
            } else {
                noteVoiceActivity()
                audioIO.playReceivedAudio(msg.audio)
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
        remoteControl.start()   // escuchar botones del intercom (Hysnox)
        startPresenceTimer()    // radar: latido de presencia
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

        // Modo música automático: arrancar en reposo (música full, sin mic).
        // El micrófono se activa solo cuando hay voz.
        if autoMusicMode {
            audioFocus = .music
            lastVoiceActivity = .distantPast
            audioQueue.async { [weak self] in
                self?.configureSessionForMusic()
            }
            startFocusTimer()
            return
        }

        // El audio se configura en background para no colgar la UI.
        audioQueue.async { [weak self] in
            guard let self else { return }
            // Respetar el switch de salida: si el rider eligió bocinas, arrancar
            // en modo música (A2DP, sin mic). Si eligió cascos, intercom HFP.
            if self.outputTarget == .speakers {
                self.configureSessionForMusic()
                self.log.info(.audioSession, "Arranque en BOCINAS (A2DP, sin mic)")
                return
            }
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

        // Ray-Ban Meta: se conectan como audífono normal pero su volumen de
        // salida es bajo. Al detectarlas, subir la ganancia de escucha una vez.
        let isRayBan = allNames.contains { $0.contains("ray-ban") || $0.contains("ray ban") || $0.contains("rayban") || $0.contains("meta") }
        if isRayBan, !rayBanAutoBoosted {
            rayBanAutoBoosted = true
            DispatchQueue.main.async {
                if self.speakerGain < 3.0 { self.speakerGain = 3.0 } // sube volumen de escucha
            }
            log.info(.audioRoute, "Ray-Ban Meta detectadas: ganancia de escucha aumentada")
        } else if !isRayBan {
            rayBanAutoBoosted = false
        }
        DispatchQueue.main.async { self.rayBanDetected = isRayBan }

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
        remoteControl.stop()
        stopPresenceTimer()
        stopFocusTimer()
        audioFocus = .music
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
        // En modo música automático, abrir el mic implica pasar a foco voz.
        if transmitting { noteVoiceActivity() }
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

    // MARK: - Conmutador música / voz (modo autoMusicMode)

    /// Marca que hubo actividad de voz (mi mic o audio entrante) y, si estamos
    /// en música, cambia a modo voz. El temporizador se encarga de volver.
    private func noteVoiceActivity() {
        lastVoiceActivity = Date()
        if autoMusicMode, audioFocus == .music {
            switchFocus(to: .voice)
        }
    }

    /// Arranca el temporizador que devuelve a música tras el silencio.
    private func startFocusTimer() {
        focusTimer?.invalidate()
        guard autoMusicMode else { return }
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.autoMusicMode, self.isRunning else { return }
            // Si estoy en voz y ya pasó el hangover sin actividad, vuelvo a música.
            if self.audioFocus == .voice,
               !self.isTransmitting,
               Date().timeIntervalSince(self.lastVoiceActivity) > self.voiceHangoverSeconds {
                self.switchFocus(to: .music)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
    }

    private func stopFocusTimer() {
        focusTimer?.invalidate()
        focusTimer = nil
    }

    /// Cambia la sesión de audio entre música (A2DP, sin mic) y voz (HFP, con mic).
    private func switchFocus(to focus: AudioFocus) {
        guard audioFocus != focus else { return }
        audioFocus = focus
        audioQueue.async { [weak self] in
            guard let self else { return }
            switch focus {
            case .music:
                self.configureSessionForMusic()
                self.audioIO.stop()   // suelta el micrófono → música full por A2DP
                self.log.info(.audioSession, "Foco: MÚSICA (A2DP, mic liberado)")
            case .voice:
                self.configureAudioSession()   // playAndRecord + HFP + duck
                try? self.audioIO.start()
                self.refreshInputs()
                self.log.info(.audioSession, "Foco: VOZ (HFP, mic activo)")
            }
        }
    }

    /// Sesión en modo música: reproducción estéreo por A2DP/CarPlay, mezclando
    /// con la música de otras apps, SIN micrófono. Usada en reposo (sin voz).
    ///
    /// Para recuperar ALTA FIDELIDAD: al venir del modo voz, el Bluetooth quedó
    /// negociado en perfil HFP (mono, calidad de llamada). iOS no re-negocia a
    /// A2DP si la sesión sigue activa con el mismo dispositivo, así que la
    /// música se oye "de llamada". La solución es DESACTIVAR la sesión primero
    /// (suelta HFP) y reconfigurar limpio en .playback → iOS re-negocia A2DP
    /// estéreo (o usa la salida CarPlay de alta calidad si está conectada).
    private func configureSessionForMusic() {
        do {
            // 1) Soltar la ruta HFP actual para forzar re-negociación.
            try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
            // 2) Categoría de reproducción pura, alta fidelidad. NO usamos
            //    .allowBluetoothHFP aquí (eso fuerza el perfil de llamada mono).
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true, options: [])
            let outs = audioSession.currentRoute.outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }
            log.info(.audioSession, "Modo música (A2DP/CarPlay HiFi): \(outs.joined(separator: ", "))")
        } catch {
            log.error(.audioSession, "Error modo música: \(error.localizedDescription)")
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
            // Buffer IO corto para menos latencia (captura + reproducción).
            try? audioSession.setPreferredIOBufferDuration(0.01) // ~10 ms
            try audioSession.setActive(true, options: [])
            log.info(.audioSession, "AudioSession lista (coexistir=\(coexistWithOtherAudio), IOBuf=\(String(format: "%.1fms", audioSession.ioBufferDuration*1000)))")
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
