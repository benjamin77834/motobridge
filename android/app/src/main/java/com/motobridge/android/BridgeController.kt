package com.motobridge.android

import android.content.Context
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.motobridge.android.audio.AudioIO
import com.motobridge.android.audio.OpusCodec
import com.motobridge.android.audio.PcmCodec
import com.motobridge.android.net.LocalNetworkTransport
import com.motobridge.android.net.TransportState

/**
 * Une el audio (AudioIO) con el transporte de red (LocalNetworkTransport).
 * Expone estado observable para la UI Compose.
 */
class BridgeController(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("monobridge", Context.MODE_PRIVATE)
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
    private var localName = prefs.getString("riderName", null)?.takeIf { it.isNotBlank() } ?: (Build.MODEL ?: "Rider")

    private val audio = AudioIO()
    private var transport = LocalNetworkTransport(appContext, localName)

    // Estado para Compose.
    var riderName by mutableStateOf(prefs.getString("riderName", "") ?: ""); private set
    var isRunning by mutableStateOf(false); private set
    var state by mutableStateOf(TransportState.NOT_CONNECTED); private set
    var peerName by mutableStateOf<String?>(null); private set
    var isTransmitting by mutableStateOf(false); private set
    var inputLevel by mutableStateOf(0f); private set
    var events by mutableStateOf(listOf<String>()); private set

    // Estado observable para los sliders de Compose.
    var micGain by mutableStateOf(3.0f)
        private set
    var speakerGain by mutableStateOf(1.0f)
        private set
    var noiseGate by mutableStateOf(0.015f)
        private set

    var opusEnabled by mutableStateOf(false)
        private set

    /** Modo "Música + intercom automático": mientras nadie habla, se libera el
     *  micrófono para que Spotify/CarPlay suene a todo volumen; al hablar tú o
     *  llegar voz de un rider, se abre el intercom (la música baja) y al cesar
     *  la voz vuelve la música. */
    var autoMusicMode by mutableStateOf(prefs.getBoolean("autoMusicMode", false))
        private set
    fun updateAutoMusicMode(on: Boolean) {
        if (autoMusicMode == on) return
        autoMusicMode = on
        prefs.edit().putBoolean("autoMusicMode", on).apply()
        if (isRunning) { stop(); android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ start() }, 400) }
    }

    /** Destino de salida elegido manualmente: cascos (intercom) o bocinas (música). */
    var outputTarget by mutableStateOf(prefs.getString("outputTarget", "headset") ?: "headset")
        private set

    /** Cambia la salida. Bocinas = libera mic (música por A2DP/CarPlay).
     *  Cascos = intercom por el audífono/Hysnox (HFP/SCO). */
    fun setOutput(target: String) {
        if (outputTarget == target) return
        outputTarget = target
        prefs.edit().putString("outputTarget", target).apply()
        if (!isRunning || autoMusicMode) return
        if (target == "speakers") { audio.stop(); routeToMedia() }
        else { routeToHeadset(); audio.start() }
    }

    /** Enruta al audífono/Hysnox (HFP): modo comunicación + SCO. */
    private fun routeToHeadset() {
        try {
            audioManager.mode = android.media.AudioManager.MODE_IN_COMMUNICATION
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                val dev = audioManager.availableCommunicationDevices.firstOrNull {
                    it.type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                }
                if (dev != null) audioManager.setCommunicationDevice(dev)
            } else {
                @Suppress("DEPRECATION")
                audioManager.startBluetoothSco()
                @Suppress("DEPRECATION")
                audioManager.isBluetoothScoOn = true
            }
        } catch (_: Exception) {}
    }

    /** Enruta a media (A2DP/CarPlay): modo normal, sin SCO. */
    private fun routeToMedia() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                audioManager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                audioManager.isBluetoothScoOn = false
                @Suppress("DEPRECATION")
                audioManager.stopBluetoothSco()
            }
            audioManager.mode = android.media.AudioManager.MODE_NORMAL
        } catch (_: Exception) {}
    }

    fun toggleOutput() { setOutput(if (outputTarget == "headset") "speakers" else "headset") }

    /** Estado visible del botón play/pausa. */
    var musicPlaying by mutableStateOf(false)
        private set

    /** Play/Pausa de la música (Spotify/YT Music/etc.) sin salir de la app.
     *  Envía la tecla multimedia PLAY_PAUSE al reproductor activo del sistema. */
    fun toggleMusic() {
        try {
            val down = android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            val up = android.view.KeyEvent(android.view.KeyEvent.ACTION_UP,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            audioManager.dispatchMediaKeyEvent(down)
            audioManager.dispatchMediaKeyEvent(up)
            musicPlaying = !musicPlaying
        } catch (_: Exception) {}
    }

    // Conmutador música/voz.
    private enum class AudioFocusState { MUSIC, VOICE }
    private var audioFocus = AudioFocusState.MUSIC
    private var lastVoiceActivity = 0L
    private val voiceHangoverMs = 1500L
    private var focusHandler: android.os.Handler? = null
    private var focusRunnable: Runnable? = null

    fun updateMicGain(v: Float) { micGain = v; audio.captureGain = v }
    fun updateSpeakerGain(v: Float) { speakerGain = v; audio.outputGain = v }
    fun updateNoiseGate(v: Float) { noiseGate = v; audio.gateThreshold = v }
    fun updateOpus(on: Boolean) {
        opusEnabled = on
        audio.codec = if (on) runCatching { OpusCodec() }.getOrDefault(PcmCodec()) else PcmCodec()
    }

    /** Relay de malla para extender alcance (compatible con iOS). */
    private val mesh = com.motobridge.android.net.MeshRelay()
    // Desactivado por defecto: solo útil con 3+ motos. Debe estar igual en todos.
    var meshEnabled by mutableStateOf(false)
        private set
    fun updateMesh(on: Boolean) { meshEnabled = on }

    init {
        wire()
        initTTS() // aviso por voz al conectar riders
        // Opus OFF por defecto (PCM es estable; Opus se activa manual en ambos).
        audio.onCaptured = { bytes, len ->
            val raw = if (bytes.size == len) bytes else bytes.copyOf(len)
            val channeled = if (channelType == com.motobridge.android.net.VoiceChannel.SUBGROUP && activeSubgroupTargets.isNotEmpty()) {
                // Voz dirigida a un subgrupo de riders elegidos.
                com.motobridge.android.net.VoiceChannel.wrapSubgroup(raw, activeSubgroupTargets, false)
            } else {
                // En alarma, el targetId transporta MI id de nombre. En privado, el id del destinatario.
                val target = if (channelType == com.motobridge.android.net.VoiceChannel.ALARM) myNameId else privateTargetId
                com.motobridge.android.net.VoiceChannel.wrap(raw, channelType, target)
            }
            val toSend = if (meshEnabled) mesh.wrapOutgoing(channeled) else channeled
            transport.sendAudio(toSend, toSend.size)
        }
        audio.onLevel = { level -> inputLevel = level }
    }

    private fun wire() {
        transport.onAudio = { peerId, packet ->
            if (meshEnabled) {
                val inc = mesh.processIncoming(packet)
                if (inc != null) {
                    if (inc.isNew) playChanneled(peerId, inc.payload)
                    if (peerName != null && peerName!!.contains(",")) {
                        inc.relay?.let { transport.sendAudio(it, it.size) }
                    }
                }
            } else {
                playChanneled(peerId, packet)
            }
        }
        transport.onState = { s -> state = s }
        transport.onPeer = { name ->
            // Detectar riders nuevos para notificar quién se conectó.
            val newSet = name?.split(",")?.map { it.trim() }?.filter { it.isNotBlank() }?.toSet() ?: emptySet()
            val added = newSet - knownPeers
            for (r in added) notifyRiderConnected(r)
            // Modo intercom: al conectar el primer rider, abrir el micrófono solo.
            if (autoIntercom && knownPeers.isEmpty() && newSet.isNotEmpty()) {
                updateTransmitting(true)
            }
            knownPeers = newSet
            peerName = name
        }
        transport.onEvent = { line ->
            events = (listOf(timestamp() + " · " + line) + events).take(12)
        }
    }

    private fun playChanneled(peerId: String, data: ByteArray) {
        val msg = com.motobridge.android.net.VoiceChannel.unwrap(data)
        if (msg == null) { audio.playFrom(peerId, data); return }
        when (msg.type) {
            com.motobridge.android.net.VoiceChannel.PRIVATE ->
                if (msg.targetId == myNameId) { noteVoiceActivity(); audio.playFrom(peerId, msg.audio) }
            com.motobridge.android.net.VoiceChannel.ALARM -> {
                noteVoiceActivity()
                audio.playFrom(peerId, msg.audio)
                val now = System.currentTimeMillis()
                if (ttsReady && now - lastAlarmAnnounce > 4000) {
                    lastAlarmAnnounce = now
                    // Anunciar QUIÉN pide ayuda (targetId trae el id de nombre del emisor).
                    val who = nameForId(msg.targetId)
                    val text = if (who.isBlank()) "Emergencia. Un rider necesita ayuda"
                               else "Emergencia. $who necesita ayuda"
                    tts?.speak(text, android.speech.tts.TextToSpeech.QUEUE_ADD, null, "alarm-rx")
                }
            }
            com.motobridge.android.net.VoiceChannel.TEXT -> {
                // Mensaje escrito: privado solo si es para mí; 0 = grupo. Se lee por TTS.
                if (msg.targetId != 0 && msg.targetId != myNameId) return
                val text = String(msg.audio, Charsets.UTF_8)
                if (text.isNotEmpty() && ttsReady) {
                    val prefix = if (msg.targetId == 0) "Mensaje del grupo. " else "Mensaje privado. "
                    tts?.speak(prefix + text, android.speech.tts.TextToSpeech.QUEUE_ADD, null, "txt-rx")
                }
            }
            com.motobridge.android.net.VoiceChannel.SUBGROUP -> {
                // Subgrupo: solo si mi nameId está en la lista de destinatarios.
                if (!msg.targets.contains(myNameId)) return
                if (msg.isText) {
                    val text = String(msg.audio, Charsets.UTF_8)
                    if (text.isNotEmpty() && ttsReady) {
                        tts?.speak("Mensaje de grupo privado. $text", android.speech.tts.TextToSpeech.QUEUE_ADD, null, "txt-rx")
                    }
                } else {
                    noteVoiceActivity(); audio.playFrom(peerId, msg.audio)
                }
            }
            else -> { noteVoiceActivity(); audio.playFrom(peerId, msg.audio) } // grupo: siempre
        }
    }

    private var knownPeers: Set<String> = emptySet()

    private var tts: android.speech.tts.TextToSpeech? = null
    private var ttsReady = false

    private fun initTTS() {
        if (tts != null) return
        tts = android.speech.tts.TextToSpeech(appContext) { status ->
            if (status == android.speech.tts.TextToSpeech.SUCCESS) {
                tts?.language = java.util.Locale("es", "MX")
                ttsReady = true
            }
        }
    }

    private fun notifyRiderConnected(rider: String) {
        // 1) Aviso por voz (se oye en el audífono/intercom, ideal para moto).
        try {
            if (ttsReady) {
                tts?.speak("$rider se conectó", android.speech.tts.TextToSpeech.QUEUE_ADD, null, "rider-$rider")
            }
        } catch (_: Exception) {}

        // 2) Notificación visual (por si estás mirando el teléfono).
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            val channelId = "monobridge_riders"
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                val ch = android.app.NotificationChannel(channelId, "Riders conectados",
                    android.app.NotificationManager.IMPORTANCE_DEFAULT)
                nm.createNotificationChannel(ch)
            }
            val notif = androidx.core.app.NotificationCompat.Builder(appContext, channelId)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Rider conectado")
                .setContentText("$rider se unió al grupo")
                .setAutoCancel(true)
                .build()
            nm.notify(rider.hashCode(), notif)
        } catch (_: Exception) {}
    }

    /** Guarda el nombre del rider y recrea el transporte para aplicarlo. */
    fun applyRiderName(name: String) {
        val clean = name.take(30).trim()
        prefs.edit().putString("riderName", clean).apply()
        riderName = clean
        if (isRunning) return
        localName = clean.ifBlank { Build.MODEL ?: "Rider" }
        transport = LocalNetworkTransport(appContext, localName)
        wire()
    }

    /** Cierra el bridge, libera audio y termina la app (no gasta batería). */
    fun shutdownAndExit() {
        stop()
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    fun start() {
        if (isRunning) return
        isRunning = true
        detectAudioQuality()
        transport.start()
        if (autoMusicMode) {
            // Arrancar en reposo: micrófono liberado, música full. Se abre al hablar.
            audioFocus = AudioFocusState.MUSIC
            lastVoiceActivity = 0L
            startFocusTimer()
        } else if (outputTarget == "speakers") {
            // Salida a bocinas: no capturar mic, deja que la música suene por A2DP.
            routeToMedia()
        } else {
            routeToHeadset()
            audio.start()
        }
        remote.start()
    }

    fun stop() {
        if (!isRunning) return
        isRunning = false
        remote.stop()
        stopFocusTimer()
        audioFocus = AudioFocusState.MUSIC
        updateTransmitting(false)
        knownPeers = emptySet()
        transport.stop()
        audio.stop()
        routeToMedia() // restaurar modo normal al salir
    }

    /** Lee los botones multimedia del intercom (Hysnox) vía MediaSession:
     *  play/pause = hablar (toggle), next = bocinas, previous = cascos. */
    private val remote by lazy {
        com.motobridge.android.net.RemoteControlManager(appContext).apply {
            onToggle = {
                if (isRunning) android.os.Handler(android.os.Looper.getMainLooper()).post {
                    updateTransmitting(!isTransmitting)
                }
            }
            onNext = { android.os.Handler(android.os.Looper.getMainLooper()).post { setOutput("speakers") } }
            onPrevious = { android.os.Handler(android.os.Looper.getMainLooper()).post { setOutput("headset") } }
        }
    }

    /** Registra actividad de voz (mi mic o audio entrante) y, si estábamos en
     *  música, abre el intercom. */
    private fun noteVoiceActivity() {
        lastVoiceActivity = System.currentTimeMillis()
        if (autoMusicMode && audioFocus == AudioFocusState.MUSIC) switchFocus(AudioFocusState.VOICE)
    }

    private fun startFocusTimer() {
        stopFocusTimer()
        if (!autoMusicMode) return
        val h = android.os.Handler(android.os.Looper.getMainLooper())
        focusHandler = h
        val r = object : Runnable {
            override fun run() {
                if (autoMusicMode && isRunning &&
                    audioFocus == AudioFocusState.VOICE && !isTransmitting &&
                    System.currentTimeMillis() - lastVoiceActivity > voiceHangoverMs) {
                    switchFocus(AudioFocusState.MUSIC)
                }
                if (isRunning) h.postDelayed(this, 300)
            }
        }
        focusRunnable = r
        h.postDelayed(r, 300)
    }

    private fun stopFocusTimer() {
        focusRunnable?.let { focusHandler?.removeCallbacks(it) }
        focusRunnable = null
        focusHandler = null
    }

    /** Alterna entre música (mic liberado, Spotify full) y voz (intercom activo). */
    private fun switchFocus(focus: AudioFocusState) {
        if (audioFocus == focus) return
        audioFocus = focus
        when (focus) {
            AudioFocusState.MUSIC -> audio.stop()   // libera mic → música full
            AudioFocusState.VOICE -> audio.start()  // abre intercom → música baja (ducking del sistema)
        }
    }

    /** Si true, al conectar un rider se abre el micrófono automáticamente
     *  (modo intercom manos libres, como una llamada). */
    var autoIntercom by mutableStateOf(true)
        private set
    fun updateAutoIntercom(on: Boolean) { autoIntercom = on }

    /** Calidad de audio detectada según el dispositivo conectado. */
    var detectedQuality by mutableStateOf("Estándar")
        private set

    // Canal de voz: grupo / privado / alarma.
    var channelType by mutableStateOf(com.motobridge.android.net.VoiceChannel.GROUP)
        private set
    var privatePeerName by mutableStateOf<String?>(null)
        private set
    private var privateTargetId = 0
    private val myNameId get() = com.motobridge.android.net.VoiceChannel.idFor(localName)

    /** Traduce un id de nombre (FNV-1a) al nombre visible de un rider conectado.
     *  Se usa en la alarma para anunciar quién pide ayuda. "" si no se reconoce. */
    private fun nameForId(id: Int): String {
        if (id == 0) return ""
        return knownPeers.firstOrNull { com.motobridge.android.net.VoiceChannel.idFor(it) == id } ?: ""
    }

    // Subgrupos (varios riders elegidos).
    data class Subgroup(val name: String, val members: List<String>)
    var subgroups by mutableStateOf(loadSubgroups())
        private set
    var activeSubgroupName by mutableStateOf<String?>(null)
        private set
    private var activeSubgroupTargets = IntArray(0)

    private fun loadSubgroups(): List<Subgroup> {
        val raw = prefs.getString("subgroups", null) ?: return emptyList()
        return try {
            val arr = org.json.JSONArray(raw)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                val mem = o.getJSONArray("members")
                Subgroup(o.getString("name"), (0 until mem.length()).map { mem.getString(it) })
            }
        } catch (_: Exception) { emptyList() }
    }
    private fun saveSubgroupsToPrefs() {
        val arr = org.json.JSONArray()
        for (sg in subgroups) {
            val o = org.json.JSONObject()
            o.put("name", sg.name)
            o.put("members", org.json.JSONArray(sg.members))
            arr.put(o)
        }
        prefs.edit().putString("subgroups", arr.toString()).apply()
    }

    fun saveSubgroup(name: String, members: List<String>) {
        val clean = name.trim()
        if (clean.isEmpty() || members.isEmpty()) return
        val list = subgroups.toMutableList()
        val idx = list.indexOfFirst { it.name == clean }
        if (idx >= 0) list[idx] = Subgroup(clean, members) else list.add(Subgroup(clean, members))
        subgroups = list
        saveSubgroupsToPrefs()
    }

    fun deleteSubgroup(name: String) {
        subgroups = subgroups.filter { it.name != name }
        if (activeSubgroupName == name) backToGroup()
        saveSubgroupsToPrefs()
    }

    fun startSubgroup(name: String) {
        val sg = subgroups.firstOrNull { it.name == name } ?: return
        activeSubgroupTargets = sg.members.map { com.motobridge.android.net.VoiceChannel.idFor(it) }.toIntArray()
        activeSubgroupName = name
        privatePeerName = null
        privateTargetId = 0
        channelType = com.motobridge.android.net.VoiceChannel.SUBGROUP
    }

    /** Texto a un subgrupo: todos sus miembros lo leen por voz. */
    fun sendTextToSubgroup(text: String, subgroup: String) {
        val clean = text.trim()
        val sg = subgroups.firstOrNull { it.name == subgroup } ?: return
        if (!isRunning || clean.isEmpty()) return
        val targets = sg.members.map { com.motobridge.android.net.VoiceChannel.idFor(it) }.toIntArray()
        val payload = clean.toByteArray(Charsets.UTF_8)
        val channeled = com.motobridge.android.net.VoiceChannel.wrapSubgroup(payload, targets, true)
        val toSend = if (meshEnabled) mesh.wrapOutgoing(channeled) else channeled
        transport.sendAudio(toSend, toSend.size)
        if (ttsReady) tts?.speak("Mensaje enviado al grupo $subgroup", android.speech.tts.TextToSpeech.QUEUE_ADD, null, "txt-tx")
    }

    fun startPrivate(peerName: String) {
        privateTargetId = com.motobridge.android.net.VoiceChannel.idFor(peerName)
        privatePeerName = peerName
        activeSubgroupName = null
        activeSubgroupTargets = IntArray(0)
        channelType = com.motobridge.android.net.VoiceChannel.PRIVATE
    }
    fun backToGroup() {
        channelType = com.motobridge.android.net.VoiceChannel.GROUP
        privatePeerName = null
        privateTargetId = 0
        activeSubgroupName = null
        activeSubgroupTargets = IntArray(0)
    }

    /** Envía un mensaje ESCRITO que el receptor leerá por voz (TTS).
     *  privateTo = nombre del rider (null = a todo el grupo). */
    fun sendTextMessage(text: String, privateTo: String? = null) {
        val clean = text.trim()
        if (!isRunning || clean.isEmpty()) return
        val target = if (privateTo != null) com.motobridge.android.net.VoiceChannel.idFor(privateTo) else 0
        val payload = clean.toByteArray(Charsets.UTF_8)
        val channeled = com.motobridge.android.net.VoiceChannel.wrap(payload, com.motobridge.android.net.VoiceChannel.TEXT, target)
        val toSend = if (meshEnabled) mesh.wrapOutgoing(channeled) else channeled
        transport.sendAudio(toSend, toSend.size)
        val who = if (privateTo != null) "a $privateTo" else "al grupo"
        if (ttsReady) tts?.speak("Mensaje enviado $who", android.speech.tts.TextToSpeech.QUEUE_ADD, null, "txt-tx")
    }

    var alarmActive by mutableStateOf(false)
        private set
    private var lastAlarmAnnounce = 0L

    /** Envía alarma de emergencia a todo el grupo (~6s), abre mic y avisa por voz. */
    fun sendAlarm() {
        if (!isRunning) return
        channelType = com.motobridge.android.net.VoiceChannel.ALARM
        alarmActive = true
        updateTransmitting(true)
        if (ttsReady) tts?.speak("Alarma enviada", android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, "alarm")
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            updateTransmitting(false)
            alarmActive = false
            channelType = if (privatePeerName != null) com.motobridge.android.net.VoiceChannel.PRIVATE
                          else com.motobridge.android.net.VoiceChannel.GROUP
        }, 6000)
    }

    /** Detecta AirPods/Beats/audífonos buenos y ajusta el procesamiento. */
    fun detectAudioQuality() {
        try {
            val am = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val devices = am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
            var high = false
            for (d in devices) {
                val name = (d.productName ?: "").toString().lowercase()
                val t = d.type
                if (name.contains("airpod") || name.contains("beats") ||
                    t == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) {
                    high = true
                }
            }
            if (high) {
                detectedQuality = "Alta (audífonos)"
                audio.gateThreshold = 0.006f
                audio.voiceEnhancementEnabled = false
            } else {
                detectedQuality = "Voz (intercom)"
                audio.gateThreshold = 0.015f
                audio.voiceEnhancementEnabled = true
            }
        } catch (_: Exception) {}
    }

    fun updateTransmitting(v: Boolean) {
        // En modo música, abrir el mic implica pasar a foco voz (arranca audio).
        if (v) noteVoiceActivity()
        isTransmitting = v
        audio.isTransmitting = v
    }

    fun localDeviceName(): String = localName

    private fun timestamp(): String {
        val f = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
        return f.format(java.util.Date())
    }
}
