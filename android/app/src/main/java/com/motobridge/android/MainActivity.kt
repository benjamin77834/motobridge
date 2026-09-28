package com.motobridge.android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.motobridge.android.net.TransportState

class MainActivity : ComponentActivity() {

    private lateinit var controller: BridgeController
    private val micGranted = mutableStateOf(false)

    private val requestMic = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> micGranted.value = granted }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        controller = BridgeController(this)

        micGranted.value = ContextCompat.checkSelfPermission(
            this, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

        // Permiso de notificaciones (Android 13+) para avisar de riders conectados.
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            if (ContextCompat.checkSelfPermission(this, "android.permission.POST_NOTIFICATIONS")
                != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 101)
            }
        }

        handleCommand(intent)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(Modifier.fillMaxSize()) {
                    BridgeScreen(
                        controller = controller,
                        micGranted = micGranted.value,
                        onRequestMic = { requestMic.launch(Manifest.permission.RECORD_AUDIO) }
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCommand(intent)
    }

    /** Ejecuta comandos que llegan por deep link (voz/asistente/accesos directos). */
    private fun handleCommand(intent: android.content.Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "motobridge") return
        when (data.lastPathSegment) {
            "start" -> controller.start()
            "stop" -> controller.stop()
            "mic_on" -> controller.updateTransmitting(true)
            "mic_off" -> controller.updateTransmitting(false)
            "volume_up" -> controller.updateSpeakerGain((controller.speakerGain + 1f).coerceAtMost(6f))
            "volume_down" -> controller.updateSpeakerGain((controller.speakerGain - 1f).coerceAtLeast(1f))
        }
    }

    override fun onDestroy() {
        controller.stop()
        super.onDestroy()
    }
}

@Composable
fun BridgeScreen(
    controller: BridgeController,
    micGranted: Boolean,
    onRequestMic: () -> Unit
) {
    var showSettings by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (showSettings) "Configuración" else "Mono Bridge",
                 fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (showSettings) {
                TextButton(onClick = { showSettings = false }) { Text("Listo") }
            } else {
                TextButton(onClick = { controller.shutdownAndExit() }) {
                    Text("Cerrar", color = Color(0xFFFF6B6B))
                }
            }
        }

        if (!micGranted) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("Se necesita permiso de micrófono para transmitir tu voz.")
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = onRequestMic) { Text("Conceder permiso") }
                }
            }
        }

        if (!showSettings) {
            MainControls(controller) { showSettings = true }
        } else {
            SettingsControls(controller)
        }
    }
}

/** Pantalla principal simple para usar en moto. */
@Composable
private fun MainControls(controller: BridgeController, onSettings: () -> Unit) {
    // Estado + iniciar/detener
    val statusColor = when (controller.state) {
        TransportState.CONNECTED -> Color(0xFF34C759)
        TransportState.CONNECTING -> Color(0xFFFFCC00)
        TransportState.NOT_CONNECTED -> Color(0xFFFF3B30)
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(16.dp).clip(RoundedCornerShape(8.dp)).background(statusColor))
                Spacer(Modifier.width(10.dp))
                Text(when (controller.state) {
                    TransportState.CONNECTED -> "CONECTADO"
                    TransportState.CONNECTING -> "CONECTANDO"
                    TransportState.NOT_CONNECTED -> "SIN CONEXIÓN"
                }, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text(controller.peerName ?: "—")
            }
            Button(
                onClick = { if (controller.isRunning) controller.stop() else controller.start() },
                modifier = Modifier.fillMaxWidth().height(56.dp)
            ) {
                Text(if (controller.isRunning) "DETENER" else "INICIAR BRIDGE", fontWeight = FontWeight.Bold)
            }
        }
    }

    // Botón grande de HABLAR (verde) + manos libres
    val talking = controller.isTransmitting
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Box(
                    Modifier.size(190.dp).clip(CircleShape)
                        .background(if (talking) Color(0xFF2E7D32) else Color(0xFF34C759))
                        .pointerInput(controller.isRunning) {
                            detectTapGestures(onPress = {
                                if (controller.isRunning) {
                                    controller.updateTransmitting(true)
                                    tryAwaitRelease()
                                    controller.updateTransmitting(false)
                                }
                            })
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Text(if (talking) "HABLANDO" else "HABLAR",
                         fontWeight = FontWeight.Black, fontSize = 28.sp, color = Color.White)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Manos libres", Modifier.weight(1f))
                Switch(checked = talking,
                       onCheckedChange = { controller.updateTransmitting(it) },
                       enabled = controller.isRunning)
            }
        }
    }

    // Canal privado rápido
    val peers = controller.peerName?.split(",")?.map { it.trim() }?.filter { it.isNotBlank() } ?: emptyList()
    if (peers.isNotEmpty()) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Privado", fontWeight = FontWeight.Bold)
                controller.privatePeerName?.let {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("🔒 Con $it", Modifier.weight(1f), color = Color(0xFFFFA000))
                        Button(onClick = { controller.backToGroup() }) { Text("Grupo") }
                    }
                } ?: run {
                    for (p in peers) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(p, Modifier.weight(1f))
                            OutlinedButton(onClick = { controller.startPrivate(p) }) { Text("Privado") }
                        }
                    }
                }
            }
        }
    }

    // Emergencia
    Button(
        onClick = { controller.sendAlarm() },
        enabled = controller.isRunning,
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F)),
        modifier = Modifier.fillMaxWidth().height(56.dp)
    ) {
        Text(if (controller.alarmActive) "ALARMA ACTIVA" else "EMERGENCIA",
             fontWeight = FontWeight.Black, color = Color.White, fontSize = 18.sp)
    }

    // Configuración
    OutlinedButton(onClick = onSettings, modifier = Modifier.fillMaxWidth().height(50.dp)) {
        Text("⚙  Configuración")
    }
}

/** Pantalla de configuración (todo el setup). */
@Composable
private fun SettingsControls(controller: BridgeController) {
    var nameField by remember { mutableStateOf(controller.riderName) }

    // Nombre del rider
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Tu nombre de rider", fontWeight = FontWeight.Bold)
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = nameField, onValueChange = { nameField = it },
                    placeholder = { Text("Ej. Ben, Piloto 1…") },
                    singleLine = true, enabled = !controller.isRunning,
                    modifier = Modifier.weight(1f)
                )
                Spacer(Modifier.width(8.dp))
                Button(onClick = { controller.applyRiderName(nameField) },
                       enabled = !controller.isRunning && nameField.isNotBlank()) { Text("Guardar") }
            }
        }
    }

    // Nivel de micrófono
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Nivel de micrófono")
            LinearProgressIndicator(
                progress = { controller.inputLevel.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(12.dp)
            )
        }
    }

    // Controles de audio
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Audio", fontWeight = FontWeight.Bold)
            Text("Ganancia de micrófono: ${"%.1f".format(controller.micGain)}×", fontSize = 13.sp)
            Slider(value = controller.micGain, onValueChange = { controller.updateMicGain(it) },
                   valueRange = 1f..6f, steps = 9)
            Text("Volumen de escucha: ${"%.1f".format(controller.speakerGain)}×", fontSize = 13.sp)
            Slider(value = controller.speakerGain, onValueChange = { controller.updateSpeakerGain(it) },
                   valueRange = 1f..6f, steps = 9)
            Text("Filtro de ruido / música: ${(controller.noiseGate * 1000).toInt()}", fontSize = 13.sp)
            Slider(value = controller.noiseGate, onValueChange = { controller.updateNoiseGate(it) },
                   valueRange = 0f..0.08f, steps = 15)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Compresión Opus", Modifier.weight(1f))
                Switch(checked = controller.opusEnabled, onCheckedChange = { controller.updateOpus(it) })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Calidad: ${controller.detectedQuality}", fontSize = 12.sp,
                     color = if (controller.detectedQuality.startsWith("Alta")) Color(0xFF34C759) else Color.Gray,
                     modifier = Modifier.weight(1f))
                TextButton(onClick = { controller.detectAudioQuality() }) { Text("Detectar") }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Iniciar en intercom al conectar", Modifier.weight(1f))
                Switch(checked = controller.autoIntercom, onCheckedChange = { controller.updateAutoIntercom(it) })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Música + intercom automático 🎵")
                    Text("La música suena a todo volumen y baja sola cuando alguien habla.",
                         fontSize = 11.sp, color = Color.Gray)
                }
                Switch(checked = controller.autoMusicMode, onCheckedChange = { controller.updateAutoMusicMode(it) })
            }
        }
    }

    Text("Ambos dispositivos deben estar en la misma red WiFi o hotspot. Usa audífonos para evitar eco.",
         fontSize = 12.sp, color = Color.Gray)
}
