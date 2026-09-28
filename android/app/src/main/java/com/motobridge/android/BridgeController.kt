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
            val channeled = com.motobridge.android.net.VoiceChannel.wrap(raw, channelType, privateTargetId)
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
                if (msg.targetId == myNameId) audio.playFrom(peerId, msg.audio)
            com.motobridge.android.net.VoiceChannel.ALARM -> {
                audio.playFrom(peerId, msg.audio)
                val now = System.currentTimeMillis()
                if (ttsReady && now - lastAlarmAnnounce > 4000) {
                    lastAlarmAnnounce = now
                    tts?.speak("Alarma de emergencia", android.speech.tts.TextToSpeech.QUEUE_ADD, null, "alarm-rx")
                }
            }
            else -> audio.playFrom(peerId, msg.audio) // grupo: siempre
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
        audio.start()
        transport.start()
    }

    fun stop() {
        if (!isRunning) return
        isRunning = false
        updateTransmitting(false)
        knownPeers = emptySet()
        transport.stop()
        audio.stop()
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

    fun startPrivate(peerName: String) {
        privateTargetId = com.motobridge.android.net.VoiceChannel.idFor(peerName)
        privatePeerName = peerName
        channelType = com.motobridge.android.net.VoiceChannel.PRIVATE
    }
    fun backToGroup() {
        channelType = com.motobridge.android.net.VoiceChannel.GROUP
        privatePeerName = null
        privateTargetId = 0
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
        isTransmitting = v
        audio.isTransmitting = v
    }

    fun localDeviceName(): String = localName

    private fun timestamp(): String {
        val f = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
        return f.format(java.util.Date())
    }
}
