import SwiftUI
import MultipeerConnectivity

/// Pantalla del bridge por red local (prototipo FASE 4).
/// Permite probar audio en vivo entre dos dispositivos (iPhone <-> iPad).
struct NetworkBridgeView: View {
    @StateObject private var controller = NetworkBridgeController.shared
    @State private var riderNameField = UserDefaults.standard.string(forKey: "riderName") ?? ""

    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // PANTALLA PRINCIPAL SIMPLE (uso en moto):
                statusCard          // estado + iniciar/detener
                outputCard          // switch Cascos <-> Bocinas (arriba, fácil alcance)
                pttCard             // botón de hablar + manos libres
                quickChannelCard    // privado rápido + volver al grupo
                alarmCard           // emergencia
                settingsButton      // abre Configuración (todo lo demás)
            }
            .padding()
        }
        .navigationTitle("Mono Bridge")
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {
                        riderNameCard
                        audioSetupCard
                        modeSelectorCard
                        coexistCard
                        peersCard
                        metricsCard
                        diagnosticCard
                        tipCard
                    }
                    .padding()
                }
                .navigationTitle("Configuración")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Listo") { showSettings = false }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    controller.shutdownAndExit()
                } label: {
                    Label("Cerrar", systemImage: "power")
                        .foregroundStyle(.red)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        DashboardView()
                    } label: {
                        Label("Estado de dispositivos", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        AudioDiagnosticsView()
                    } label: {
                        Label("Audio Diagnostics", systemImage: "waveform")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Cards

    // Botón para abrir la configuración (todo lo de setup).
    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Configuración", systemImage: "gearshape.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
    }

    // Canal privado rápido: elegir con quién hablar en privado desde la principal.
    private var quickChannelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canal").font(.headline)
            if controller.connectedPeers.isEmpty {
                Text("Sin riders conectados aún.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let priv = controller.privatePeerName {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("Privado con \(priv)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Volver al grupo") { controller.backToGroup() }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
            } else {
                Text("Toca un rider para hablar en privado (sigues oyendo al grupo):")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(controller.connectedPeers) { peer in
                    Button {
                        controller.startPrivate(with: peer.name)
                    } label: {
                        HStack {
                            Image(systemName: "lock").foregroundStyle(.blue)
                            Text(peer.name)
                            Spacer()
                            Text("Privado").font(.caption.weight(.bold)).foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var statusColor: Color {
        switch controller.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .notConnected: return .red
        }
    }

    private var statusIcon: String {
        switch controller.state {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .notConnected: return "xmark.circle.fill"
        }
    }

    private var statusCard: some View {
        VStack(spacing: 16) {
            // Banner de estado grande y de alto contraste (legible en moto).
            HStack(spacing: 14) {
                Image(systemName: statusIcon)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.rawValue.uppercased())
                        .font(.title2.weight(.heavy))
                    Text(controller.connectedPeers.isEmpty
                         ? "Sin dispositivos"
                         : "\(controller.connectedPeers.count) rider(s) en el grupo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(statusColor.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                if controller.isRunning { controller.stop() } else { controller.start() }
            } label: {
                Text(controller.isRunning ? "DETENER" : "INICIAR BRIDGE")
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? .red : .green)
        }
        .cardStyle()
    }

    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnóstico").font(.headline)
            row("Modo", controller.mode.rawValue)
            row("Este dispositivo", controller.localName)
            row("Descubiertos", "\(controller.discoveredPeers.count)")
            row("Conectados", "\(controller.connectedPeers.count)")

            if !controller.events.isEmpty {
                Divider()
                Text("Eventos").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(controller.events, id: \.self) { ev in
                    Text(ev).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private var peersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dispositivos cercanos")
                .font(.headline)

            if controller.connectedPeers.isEmpty && controller.discoveredPeers.isEmpty {
                Text(controller.isRunning ? "Buscando…" : "Inicia el bridge para buscar dispositivos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(controller.connectedPeers) { peer in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(peer.name)
                    Spacer()
                    // Botón de canal privado (susurro) con este rider.
                    if controller.privatePeerName == peer.name {
                        Button {
                            controller.backToGroup()
                        } label: {
                            Label("Volver al grupo", systemImage: "lock.fill")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Button {
                            controller.startPrivate(with: peer.name)
                        } label: {
                            Label("Privado", systemImage: "lock")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                }
            }

            // Indicador de canal privado activo.
            if let priv = controller.privatePeerName {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("Privado con \(priv) — solo tu voz le llega a esta persona")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Grupo") { controller.backToGroup() }
                        .font(.caption.weight(.bold))
                }
            }

            ForEach(controller.discoveredPeers.filter { d in !controller.connectedPeers.contains(where: { $0.id == d.id }) }) { peer in
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.blue)
                    Text(peer.name)
                    Spacer()
                    Text("Detectado").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Switch de salida: Cascos (intercom) <-> Bocinas (música de la moto).
    private var outputCard: some View {
        VStack(spacing: 8) {
            Text("SALIDA DE AUDIO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    controller.setOutput(.headset)
                } label: {
                    Label("Cascos", systemImage: "headphones")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.outputTarget == .headset ? .green : .gray)

                Button {
                    controller.setOutput(.speakers)
                } label: {
                    Label("Bocinas", systemImage: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.outputTarget == .speakers ? .green : .gray)
            }
            .disabled(!controller.isRunning || controller.autoMusicMode)

            // Play/Pausa de la música (Spotify/Apple Music) sin salir de la app.
            Button {
                controller.toggleMusic()
            } label: {
                Label(controller.musicPlaying ? "Pausar música" : "Reproducir música",
                      systemImage: controller.musicPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Text(controller.autoMusicMode
                 ? "En modo automático la salida cambia sola al hablar."
                 : "Cascos = intercom con micrófono. Bocinas = música de la moto (CarPlay). El botón de música controla Spotify/Apple Music sin salir de la app.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
        .onAppear { controller.refreshMusicState() }
    }

    private var alarmCard: some View {
        VStack(spacing: 8) {
            Button {
                controller.sendAlarm()
            } label: {
                Label(controller.alarmActive ? "ALARMA ACTIVA" : "EMERGENCIA",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.heavy))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!controller.isRunning)

            Text("Envía una alerta de voz a TODO el grupo, aunque estén en privado o con música.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var coexistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $controller.autoMusicMode) {
                Text("Música + intercom automático 🎵")
                    .font(.headline)
            }
            .tint(.green)
            Text("Ideal para Spotify/CarPlay en la moto: la música suena a todo volumen por las bocinas y baja sola cuando alguien habla; al terminar, vuelve la música. El micrófono se libera mientras nadie habla. Desactiva el modo llamada.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle(isOn: $controller.coexistWithOtherAudio) {
                Text("No interrumpir música de la moto")
                    .font(.headline)
            }
            .tint(.green)
            .disabled(controller.useCallKit || controller.autoMusicMode)
            Text("Activado: la voz del intercom se suma sobre la música de CarPlay/Spotify sin pausarla (baja un poco al hablar).")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle(isOn: $controller.useCallKit) {
                Text("Modo llamada (micrófono de intercom)")
                    .font(.headline)
            }
            .tint(.blue)
            .disabled(controller.autoMusicMode)
            Text("Recomendado (activado). iOS trata el bridge como una llamada real: así los comandos de voz de Siri siguen funcionando aunque estés conectado, y se activa el micrófono de intercoms como el FreedConn. No compatible con 'no interrumpir música'. Si el bridge está activo, se reinicia solo al cambiarlo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Paso 0: nombre del rider (cómo te identificas en el grupo).
    private var riderNameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tu nombre de rider").font(.headline)
            HStack {
                TextField("Ej. Ben, Piloto 1…", text: $riderNameField)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isRunning)
                Button("Guardar") {
                    controller.applyRiderName(riderNameField)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRunning || riderNameField.isEmpty)
            }
            Text(controller.isRunning
                 ? "Detén el bridge para cambiar tu nombre."
                 : "Así te verán los demás motociclistas del grupo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Paso 1: configurar audio ANTES de conectar. Elegir micrófono y salida
    // (audífono/intercom) primero, para que la ruta quede seteada.
    private var audioSetupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Audio (elige primero)").font(.headline)

            Button {
                controller.prepareAudioRoutes()
            } label: {
                Label("Detectar audífonos / intercom", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)

            if controller.availableInputs.isEmpty {
                Text("Pulsa para detectar tus dispositivos de audio conectados.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(controller.availableInputs) { input in
                Button {
                    controller.selectInput(input)
                } label: {
                    HStack {
                        Image(systemName: controller.selectedInputUID == input.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(input.name)
                            Text(input.type).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()
            Text("Escuchar por").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button { controller.selectOutputSpeaker(false) } label: {
                    Label("Audífono / Intercom", systemImage: "headphones")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                Button { controller.selectOutputSpeaker(true) } label: {
                    Label("Altavoz", systemImage: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
            }

            Button {
                controller.forceBluetoothMic()
            } label: {
                Label("Micrófono de intercom (modo llamada)", systemImage: "phone.arrow.up.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Text("Entrada actual: \(controller.inputRoute)")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: controller.detectedQuality == .high ? "star.fill" : "waveform")
                    .foregroundStyle(controller.detectedQuality == .high ? .green : .secondary)
                Text("Calidad: \(controller.detectedQuality.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(controller.detectedQuality == .high ? .green : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var modeSelectorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. Modo de conexión").font(.headline)
            Picker("Modo", selection: Binding(
                get: { controller.mode },
                set: { controller.setMode($0) }
            )) {
                ForEach(TransportMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isRunning)

            Text(controller.mode.explanation)
                .font(.caption).foregroundStyle(.secondary)

            if controller.isRunning {
                Text("Detén el bridge para cambiar de modo.")
                    .font(.caption2).foregroundStyle(.orange)
            }

            Divider()

            Toggle(isOn: $controller.meshEnabled) {
                Text("Malla / relay (3+ motos)")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.blue)
            Text("Cada moto retransmite para extender el alcance en grupos grandes. Déjalo APAGADO para 2 dispositivos. Debe estar igual en todos.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var inputSelectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Micrófono").font(.headline)
                Spacer()
                Button {
                    controller.refreshInputs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            if controller.availableInputs.isEmpty {
                Text("Inicia el bridge para ver las entradas disponibles.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(controller.availableInputs) { input in
                Button {
                    controller.selectInput(input)
                } label: {
                    HStack {
                        Image(systemName: controller.selectedInputUID == input.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(input.name)
                            Text(input.type).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                controller.forceBluetoothMic()
            } label: {
                Label("Usar micrófono del intercom (modo llamada)", systemImage: "phone.arrow.up.right")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Text("Si el intercom (FreedConn) solo activa el micrófono en llamadas, pulsa el botón de arriba: fuerza el modo llamada y su micrófono HFP.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            // Salida: dónde escuchas (dispositivo BT/auto o altavoz del teléfono).
            Text("Escuchar por").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button { controller.selectOutputSpeaker(false) } label: {
                    Label("Audífono / Intercom", systemImage: "headphones")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                Button { controller.selectOutputSpeaker(true) } label: {
                    Label("Altavoz", systemImage: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
            }
            Text("Ruta actual — Entrada: \(controller.inputRoute)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var pttCard: some View {
        VStack(spacing: 14) {
            Text("TRANSMISIÓN")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Modo micrófono siempre abierto (toggle) para probar sin depender
            // del gesto de PTT. Útil para diagnosticar.
            Toggle(isOn: Binding(
                get: { controller.isTransmitting },
                set: { controller.setTransmitting($0) }
            )) {
                Text("Micrófono abierto")
                    .font(.title3.weight(.bold))
            }
            .toggleStyle(.switch)
            .tint(.green)

            Toggle(isOn: $controller.autoIntercom) {
                Text("Iniciar en intercom al conectar")
                    .font(.subheadline)
            }
            .tint(.green)

            // Push-to-talk con gesto.
            // Botón CIRCULAR VERDE grande de hablar. Mantener para transmitir.
            HStack {
                Spacer()
                Text(controller.isTransmitting ? "HABLANDO" : "HABLAR")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 130, height: 130)
                    .background(
                        Circle().fill(controller.isTransmitting ? Color(red: 0.18, green: 0.49, blue: 0.20) : Color(red: 0.20, green: 0.78, blue: 0.35))
                    )
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in controller.setTransmitting(true) }
                            .onEnded { _ in controller.setTransmitting(false) }
                    )
                Spacer()
            }
            .padding(.vertical, 8)

            // Medidor de nivel del micrófono (funciona aunque no transmitas).
            VStack(alignment: .leading, spacing: 4) {
                Text("Nivel de micrófono")
                    .font(.subheadline)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(controller.inputLevel > 0.02 ? Color.green : Color.gray)
                            .frame(width: geo.size.width * CGFloat(min(1, controller.inputLevel)))
                    }
                }
                .frame(height: 16)
                Text("Entrada: \(controller.inputRoute)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Ganancia de micrófono: \(String(format: "%.1f×", controller.micGain))")
                    .font(.subheadline)
                Slider(value: $controller.micGain, in: 1.0...6.0, step: 0.5)
                    .tint(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Volumen de escucha: \(String(format: "%.1f×", controller.speakerGain))")
                    .font(.subheadline)
                Slider(value: $controller.speakerGain, in: 1.0...6.0, step: 0.5)
                    .tint(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Filtro de ruido / música: \(Int(controller.noiseGate * 1000))")
                    .font(.subheadline)
                Slider(value: $controller.noiseGate, in: 0.0...0.08, step: 0.005)
                    .tint(.orange)
                Text("Sube este filtro para que la música/ruido de fondo no pase cuando no hablas. Filtra la banda de voz (300–3400 Hz).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Toggle(isOn: $controller.opusEnabled) {
                Text("Compresión Opus (recomendado)")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.blue)
            Text("Comprime la voz ~10×: mejor calidad y menos datos. Ideal para grupo e Internet. Actívalo en todos los dispositivos.")
                .font(.caption2).foregroundStyle(.secondary)

            Text("Sube la ganancia de micrófono si tu voz llega baja. El volumen de escucha ayuda con salidas bajas (Ray-Ban). Para máximo aislamiento de voz: mientras hablas, abre el Centro de Control → Modo de micrófono → Aislamiento de voz.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Métricas").font(.headline)
            HStack {
                Text("Paquetes enviados").foregroundStyle(.secondary)
                Spacer(); Text("\(controller.packetsSent)")
            }
            HStack {
                Text("Paquetes recibidos").foregroundStyle(.secondary)
                Spacer(); Text("\(controller.packetsReceived)")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Consejo para la prueba", systemImage: "lightbulb.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Si los dos dispositivos están cerca sin audífonos, habrá eco/acople. Usa audífonos en al menos uno, o sepáralos. El push-to-talk evita que ambos micrófonos estén abiertos a la vez.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

#Preview {
    NavigationStack {
        NetworkBridgeView()
    }
    .preferredColorScheme(.dark)
}
