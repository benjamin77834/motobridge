# CHANGELOG — MotoBridge

Formato basado en [Keep a Changelog](https://keepachangelog.com/).

## [0.8.1] — 2026-09-24

### Fix de estabilidad — el mesh causaba desconexiones con 2 dispositivos
- **Mesh/relay DESACTIVADO por defecto** (iOS y Android). El envoltorio de mesh añadía overhead y desajustes que rompían la conexión iPad↔iPhone. Ahora con 2 dispositivos la transmisión es directa y estable. El mesh es un interruptor opcional ("Malla / relay") para grupos de 3+ motos (debe estar igual en todos).
- Multipeer: `encryptionPreference` a `.optional` (menos fallos de handshake) y envío de audio en `.unreliable` (no satura el canal con audio en vivo).
- Selector de micrófono: ya no reinicia el motor de audio al cambiar (eso tiraba la conexión); ahora cambia la entrada en caliente.
- Nuevo control de **salida** ("Escuchar por": audífono/intercom vs altavoz).
- **Verificado en hardware por el usuario**: transmisión iPad↔iPhone estable con mesh apagado. ✅

## [0.8.0] — 2026-09-24

### Mesh relay (malla multi-salto) — extiende el alcance entre motos
- Cada dispositivo **reenvía a sus vecinos** el audio recibido de otros, encadenando el alcance (Moto A→B→C→D). Cada moto actúa como repetidor.
- **Cabecera de mesh** común iOS/Android: originId(4) + packetId(4) + ttl(1). **Deduplicación** por (origin, packet) para evitar bucles; **TTL=3** por defecto (equilibrio alcance/latencia).
- `MeshRelay` en iOS (Swift) y Android (Kotlin), compatibles entre sí.
- Integrado en el controller de ambas plataformas: reproducir si es nuevo + reenviar con TTL-1.
- Funciona mejor en **modo Apple (Multipeer)** donde los enlaces son directos peer-to-peer entre motos (no requiere router). En modo Universal actúa como respaldo dentro de la red.

### Reconexión automática
- Confirmado en iOS Multipeer: advertising/browsing siempre activos; al reaparecer un peer (volver al rango) se reinvita y reconecta solo.

### Verificado
- iOS compila. APK Android compila.
- Mesh/relay y reconexión **no probados en hardware con múltiples motos** (requiere 3+ dispositivos separándose). Lógica lista.
- Límite honesto: cada salto añade latencia; ~2-3 saltos es lo realista para voz. Opus (ya integrado) hace el relay más viable al reducir el tráfico retransmitido.

## [0.7.0] — 2026-09-24

### Compresión de audio Opus
- **Capa de códec** (`AudioCodec`) con cabecera de 1 byte por paquete (0x00 PCM / 0x01 Opus) para que convivan dispositivos con y sin Opus.
- **iOS**: `OpusCodec` real usando `swift-opus` (SPM, integrado en project.yml). Comprime ~10× (16 kHz mono, modo VoIP). Compila y resuelve el paquete.
- **Android**: `OpusCodec` con MediaCodec nativo (sin dependencias externas), con caída automática a PCM si el dispositivo no lo soporta.
- Toggle "Compresión Opus" en ambas apps.

### Verificado
- iOS compila (swift-opus resuelto). APK Android compila.
- **No probado en hardware la interoperabilidad Opus iOS↔Android** — el Opus de MediaCodec (Android) y libopus (iOS) pueden no ser bit-compatibles en tiempo real sin ajustes. Modo seguro entre plataformas distintas: PCM. Opus validado conviene primero same-platform (iOS↔iOS, Android↔Android).

## [0.6.0] — 2026-09-24

### Comunicación en grupo (multi-rider) — iOS y Android
- **Grupo de hasta 6 personas** (5 conexiones + tú), límite común en ambas plataformas.
- **iOS modo Apple (Multipeer)**: acepta/invita a varios peers hasta el límite; el `AVAudioEngine` mezcla las voces entrantes automáticamente.
- **iOS modo Universal (UDP)**: `LocalNetworkTransport` reescrito para múltiples conexiones (`[nombre: NWConnection]`), envío a todos, auto-conexión a todos los descubiertos.
- **Android**: `LocalNetworkTransport.kt` con lista de peers (envío a todos) + **mixer de audio** (`AudioIO` suma los streams de varios emisores en un hilo de salida, para que hablen a la vez sin entrecortarse). `onAudio` ahora identifica al emisor.
- UI: estado muestra "N rider(s) en el grupo"; lista de dispositivos conectados.

### Verificado
- iOS compila (7 tests pasan). APK Android compila.
- Grupo no probado en hardware con >2 dispositivos (requiere varios equipos en red).
- Nota honesta: con audio sin comprimir, lo realista son 3–5 riders en WiFi local; para más se necesitaría compresión (Opus), no incluida aún.

## [0.5.0] — 2026-09-17

### App Android (proyecto nuevo en `android/`)
- Proyecto Android Studio (Kotlin + Jetpack Compose) que implementa `PROTOCOL.md` para interoperar con el modo Universal de iOS.
- `MotoBridgePacket.kt`: protocolo de paquete idéntico al de iOS (magic 0x4D, versión, tipo audio, PCM Int16 LE mono 8 kHz).
- `LocalNetworkTransport.kt`: descubrimiento con **NsdManager** (`_motobridge._udp`) + transporte **UDP** (`DatagramSocket`), regla de conexión por nombre, adopción del emisor por recepción.
- `AudioIO.kt`: `AudioRecord` (VOICE_COMMUNICATION, 8 kHz mono) con **AcousticEchoCanceler + NoiseSuppressor**, `AudioTrack`, ganancias de captura/salida, medidor de nivel.
- `BridgeController.kt` + `MainActivity.kt`: UI Compose con estado, push-to-talk, nivel de micrófono y eventos; solicitud de permiso de micrófono.
- `android/README.md` con pasos para abrir/compilar en Android Studio.

### Verificado
- Código iOS y watchOS siguen compilando (7 tests pasan).
- **El proyecto Android NO se compiló en este entorno** (no hay SDK de Android ni Gradle aquí, solo herramientas iOS/Xcode). Debe compilarse y probarse en Android Studio. Documentado en `android/README.md`.

### iOS — fix
- Corregido warning `'where' only applies to the second pattern match` en `LocalNetworkTransport.swift` (casos `.failed`/`.waiting` separados).
- La pantalla de inicio de la app iOS ahora es el **Network Bridge**; Dashboard/Diagnostics/Settings pasaron a un menú.

## [0.4.0] — 2026-09-16

### Doble transporte (Apple + Universal/Android)
- **Abstracción `AudioTransport`**: el bridge ya no depende de un transporte concreto. El audio (`AudioIO`), ganancias, AEC, selector de micrófono y Watch quedan intactos.
- **Modo Apple (Multipeer)**: `PeerBridgeSession` conforma `AudioTransport`. iPhone ↔ iPhone/iPad, sin configuración (WiFi directo/Bluetooth). Igual que antes.
- **Modo Universal (Android)**: nuevo `LocalNetworkTransport` con **Network framework (UDP + Bonjour/mDNS)**. Compatible con Android; ambos en la misma red WiFi/hotspot. Descubrimiento por `_motobridge._udp`, auto-conexión determinista por nombre, datagramas de audio con protocolo neutral (`MotoBridgePacket`).
- **Selector de modo** en la UI (Apple / Universal), deshabilitado mientras el bridge corre.
- **`PROTOCOL.md`**: especificación del protocolo neutral para implementar la app Android (descubrimiento, regla de conexión, formato de paquete, parámetros de audio 8 kHz mono Int16, checklist Android).

### Verificado
- Compila limpio (iOS + watchOS simulador) y 7 tests pasan.
- Nota: el modo Universal está listo en iOS; la **app Android** es una fase de proyecto aparte que implementa `PROTOCOL.md`.

## [0.3.0] — 2026-09-16

### Mejoras al bridge por red (tras validación en hardware real)
- **Cancelación de eco (AEC)**: `AudioIO` habilita `setVoiceProcessingEnabled(true)` en input/output del `AVAudioEngine`. Permite manos libres bidireccional a la vez sin acoples.
- **Reconexión automática**: `PeerBridgeSession.scheduleReconnect()` reintenta la conexión si un peer se cae y sigue anunciándose; el descubrimiento nunca se detiene mientras el bridge está activo.
- **Selector de micrófono**: elegir entrada de audio (AirPods, Hysnox, FreedConn, mic del teléfono). Reinicia el engine al cambiar (`AudioIO.restart()`).
- **Medidor de nivel de micrófono** y **ganancia digital ajustable** (1×–6×).
- **UX para moto**: banner de estado grande y de alto contraste (verde/amarillo/rojo), botones grandes, tarjetas reordenadas por prioridad de uso.

### Hallazgos en hardware real (documentados en KNOWN_LIMITATIONS)
- El micrófono del **FreedConn T-COM VB no funciona vía HFP** con iOS (su altavoz sí). Mitigado usando AirPods/audífonos con micrófono en ese lado.
- Confirmado el compromiso **A2DP (alta calidad, sin mic) vs HFP (mono, con mic)**.

### Apple Watch — Push-to-talk remoto
- Nuevo target **MotoBridgeWatch** (watchOS 10+): botón grande de PTT en la muñeca.
- `WatchBridge` (iOS) + `WatchConnectivityClient` (watchOS) vía WatchConnectivity: el Watch envía el comando PTT y el iPhone transmite; el audio permanece en el iPhone (L11).
- El Watch refleja el estado de conexión del bridge.

### Verificado
- Compila limpio (iOS y watchOS simulador) y 7 tests pasan.
- **Validado en hardware real**: audio bidireccional entre dos dispositivos por red local (Hysnox ↔ AirPods).
- Nota: para instalar en dispositivos físicos hay que asignar el Development Team en Xcode (firma), igual que la app iOS.

## [0.2.0] — 2026-09-16

### Prototipo FASE 4 — Bridge de audio por red local
- `PeerBridgeSession` (Core/Network): transporte peer-to-peer con **MultipeerConnectivity**. Descubrimiento automático simétrico y auto-conexión; funciona en mismo WiFi, hotspot o sin red (WiFi directo/Bluetooth). Envío de audio en modo `.unreliable` para baja latencia.
- `AudioIO` (Core/Audio): captura de micrófono y reproducción con **AVAudioEngine**; formato de red PCM Int16 mono 16 kHz con conversores; push-to-talk vía `isTransmitting`.
- `NetworkBridgeController` (Core/Bridge): une audio y red; configura `AVAudioSession` (playAndRecord/voiceChat).
- `NetworkBridgeView` (Features/PushToTalk): UI de descubrimiento, conexión, push-to-talk y métricas de paquetes. Enlazada desde el Dashboard.
- `Info.plist`: `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_motobridge._tcp/_udp`), `UIBackgroundModes` audio+voip. Se quitó `armv7` para permitir iPad.
- `project.yml`: `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad).
- Icono de app: imagen del gorila camionero (recorte cuadrado de `gorila-banner.png`).
- Nueva guía: `NETWORK_BRIDGE_TEST.md` (pasos para probar iPhone ↔ iPad).

### Verificado
- Compila limpio (BUILD SUCCEEDED) y 7 tests pasan.
- **Pendiente:** prueba de audio real en dos dispositivos físicos (el simulador no soporta micrófono real ni multipeer entre equipos).

## [0.1.0] — 2026-09-16

### FASE 0 — Factibilidad
- `FEASIBILITY_REPORT.md` con conclusión **🔴 RED** para el bridge Bluetooth↔Bluetooth directo en un solo iPhone, evidencia técnica de CoreBluetooth/AVAudioSession, y arquitectura alternativa (bridge por red entre dos iPhones).

### FASE 1 — Proyecto base
- Proyecto Xcode generado con **XcodeGen** (`project.yml`), target iOS 17+, SwiftUI, dark mode.
- Estructura modular (App / Core / Features / Models / Services / Resources).
- `Logger` central (DEBUG/INFO/WARNING/ERROR) con export de diagnóstico.
- `AudioSessionManager`: configuración de `AVAudioSession`, activación, rutas, notificaciones de cambio de ruta e interrupción.
- Protocolo `IntercomDevice` + adaptadores `FreedConnDevice` / `HysnoxDevice`.
- `AudioBridge` (máquina de estados) que reporta la limitación de iOS de forma honesta.
- `DashboardView`, `SettingsView`, `LogView`.
- `Info.plist` con permisos de Bluetooth y Micrófono explicados.

### FASE 3 — Audio Diagnostics
- `AudioDiagnosticsView`: input/output actual, available inputs, sample rate, canales, categoría/modo, cambios de ruta, interrupciones.
- **Veredicto experimental** de rutas Bluetooth simultáneas calculado desde los puertos reales de `AVAudioSession` (no inventado).

### Testing
- 7 tests unitarios (AudioBridge, Device, Logger). **TEST SUCCEEDED**.

### Verificado
- Compila limpio en simulador iPhone 17 / iOS 26.5 (Xcode 26.6). Sin warnings de deprecación.

### Pendiente
- Verificación en hardware real (FASE 7).
- FASE 2 (Bluetooth BLE informativo), FASE 4 (bridge por red), FASE 5 (PTT real), FASE 6 (pulido UX).
