# PROTOCOL.md — Protocolo de red neutral MotoBridge (modo Universal)

Este documento define el protocolo que usa el **modo Universal** del bridge, para que **iOS y Android interoperen**. La app iOS ya lo implementa en `LocalNetworkTransport.swift`. La futura app Android debe implementar exactamente lo mismo.

> El modo **Apple (Multipeer)** NO usa este protocolo (es propietario de Apple, solo iPhone↔iPhone/iPad). Este protocolo aplica solo al modo **Universal (Android)**.

---

## 1. Modelo de red

- Ambos dispositivos deben estar en la **misma red local** (WiFi de infraestructura o hotspot de uno de ellos).
- Descubrimiento por **Bonjour/mDNS**.
- Transporte de audio por **UDP** (baja latencia; se acepta pérdida ocasional de paquetes).
- Topología: **grupo (malla)** de hasta **6 personas** (5 peers + tú). Cada dispositivo envía su audio a **todos** los demás y **mezcla** los streams entrantes. También funciona 1 a 1 (piloto ↔ copiloto).
- Límite común iOS/Android: `maxPeers = 5` conexiones.

---

## 2. Descubrimiento (Bonjour / mDNS)

- **Tipo de servicio:** `_motobridge._udp`
- **Dominio:** `local.`
- **Nombre de instancia:** el nombre del dispositivo (p. ej. "iPhone de Ben", "Pixel 8").

Cada dispositivo:
1. **Publica** un servicio `_motobridge._udp` con un puerto UDP donde escucha.
2. **Busca** servicios `_motobridge._udp` en la red.
3. Al encontrar un peer con **nombre distinto**, aplica la regla de conexión (§3).

### Android
- Usar **NsdManager** (Network Service Discovery) para publicar y descubrir `_motobridge._udp`.
- Resolver el servicio para obtener host + puerto del peer.

### iOS (referencia)
- `NWListener` con `NWListener.Service(name:type:)` publica el servicio.
- `NWBrowser` con `.bonjour(type:domain:)` descubre.

---

## 3. Regla de conexión (evitar doble conexión cruzada)

Para que solo un lado inicie la conexión y no se crucen:

- Comparar los **nombres de instancia** como cadenas.
- **El de nombre "menor" (orden lexicográfico) inicia** la conexión UDP hacia el otro.
- El de nombre "mayor" **espera** la conexión entrante.

Esto garantiza una única sesión 1:1 determinista.

---

## 4. Formato del datagrama de audio

Cada paquete UDP transporta un bloque de audio con esta cabecera de 4 bytes seguida del PCM:

```
Offset  Tamaño  Campo         Valor
0       1       magic         0x4D  ('M')
1       1       version       0x01
2       1       type          0x01  (audio PCM)
3       1       reserved      0x00
4..N    var     payload       PCM Int16 little-endian, mono, 8 kHz
```

- **magic**: siempre `0x4D`. Los paquetes que no empiecen con este byte se descartan.
- **version**: `0x01` en esta versión del protocolo.
- **type**: `0x01` = audio. (Reservado para futuros tipos: control, ping, etc.)
- **payload**: muestras PCM de 16 bits con signo, **little-endian**, un canal (mono), a **8000 Hz**.

### Tamaño de bloque recomendado
- Bloques de ~20–128 ms de audio (p. ej. 160–1024 muestras). Bloques pequeños = menor latencia.

### Decodificación
Un receptor válido:
1. Verifica `packet.length > 4`, `packet[0] == 0x4D`, `packet[2] == 0x01`.
2. Extrae `payload = packet[4..]` como PCM Int16 LE mono 8 kHz y lo reproduce.

---

## 5. Parámetros de audio (obligatorios para interoperar)

| Parámetro | Valor |
|---|---|
| Codec | PCM lineal sin comprimir |
| Profundidad | 16 bits con signo (Int16) |
| Endianness | Little-endian |
| Canales | 1 (mono) |
| Sample rate | 8000 Hz |

> 8 kHz coincide con el sample rate de HFP (intercoms/AirPods), evitando reconversión. Si en el futuro se sube la calidad, incrementar `version` y negociar.

### Android — captura y reproducción
- **Captura:** `AudioRecord` con `MediaRecorder.AudioSource.VOICE_COMMUNICATION` (activa AEC/NS del sistema), `SAMPLE_RATE = 8000`, `CHANNEL_IN_MONO`, `ENCODING_PCM_16BIT`.
- **Reproducción:** `AudioTrack` con `STREAM_VOICE_CALL` o `AudioAttributes` de comunicación, mismos parámetros.
- **Eco:** habilitar `AcousticEchoCanceler` y `NoiseSuppressor` sobre el `AudioRecord.audioSessionId` si el dispositivo los soporta.

---

## 6. Ciclo de vida

1. **Start:** publicar servicio + empezar a buscar.
2. **Descubierto un peer** con nombre distinto → aplicar regla §3.
3. **Conexión UDP** establecida → empezar a enviar/recibir datagramas de audio.
4. **Push-to-talk:** solo se envían datagramas mientras el usuario transmite (o micrófono abierto).
5. **Desconexión:** si no llegan paquetes en ~5 s o la conexión falla, volver a descubrimiento y reconectar (regla §3).
6. **Stop:** cancelar listener, browser y conexión.

---

## 7. Consideraciones

- **Sin cifrado por ahora:** el modo Universal envía audio en claro por la red local. Para producción se recomienda añadir cifrado (p. ej. DTLS) en una versión futura del protocolo (subir `version`).
- **Hotspot con aislamiento de clientes:** algunos hotspots aíslan a los clientes entre sí y bloquean el tráfico UDP directo. En ese caso, usar un WiFi compartido normal o el modo Apple entre dispositivos Apple.
- **NAT/redes distintas:** este protocolo es para **red local**. Comunicación entre redes distintas (por internet) requeriría un servidor de señalización + TURN (fase futura, p. ej. WebRTC).

---

## 8. Checklist para la app Android

- [ ] Publicar y descubrir `_motobridge._udp` con `NsdManager`.
- [ ] Regla de conexión por nombre (§3).
- [ ] Socket UDP (`DatagramSocket`) enviando/recibiendo datagramas con la cabecera §4.
- [ ] Captura `AudioRecord` 8 kHz mono Int16 + AEC/NS.
- [ ] Reproducción `AudioTrack` 8 kHz mono Int16.
- [ ] Push-to-talk y ganancias (opcional, equivalentes a la app iOS).
- [ ] Permisos: `RECORD_AUDIO`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` (para mDNS), `INTERNET`.

Con esto, un teléfono Android y un iPhone en modo Universal, en la misma red WiFi/hotspot, deberían establecer audio bidireccional.

---

## 9. Pickup ("X quiere conectarse") y timbre de conexión

**Decisión:** no se crea un tipo nuevo de datagrama (§4). El pickup reutiliza la capa de canal `VoiceChannel` (la misma de grupo/privado/alarma/texto/presencia) con un **tipo nuevo reservado**:

```
byte 0     : 0x56 ('V')
byte 1     : 0x07  (pickup)
bytes 2..5 : targetId (UInt32 big-endian) = FNV-1a del nombre del destinatario; 0 = desconocido
bytes 6..N : nombre del emisor, UTF-8
```

Cuándo se envía: el usuario toca **Conectar** sobre un dispositivo de la lista de cercanos. Además de iniciar la conexión, se manda un pickup por el canal disponible:

- **Multipeer (iPhone/iPad/Mac):** como `context` de la invitación (`invitePeer(..., withContext:)`), porque aún no hay sesión por la que mandar datos. Los peers viejos ignoran el contexto.
- **UDP/Bonjour (Android/iOS/Mac):** como datagrama normal (§4, cabecera `M`) hacia el dispositivo, con malla (`MeshRelay`) si está activa. En Android basta resolver NSD y escribir; en iOS se abre la conexión saliente aunque la regla §3 diga que debía esperar.
- Si el dispositivo está en ambos canales llegan dos pickups: el receptor ignora repetidos del mismo emisor durante 8 s.

Al recibirlo (si `targetId` es 0 o el propio):
1. Aviso discreto: timbre corto de dos toques (volumen bajo) y texto "X quiere conectarse".
2. Conexión de vuelta: en Multipeer se **acepta la invitación** que lo transportó (aunque el auto-conectar esté apagado) y no se invita de vuelta durante 12 s; el desempate por UID (iOS/Mac) y la regla de nombre menor (UDP) no cambian. En UDP el emisor ya queda como peer al recibir su paquete y se evita abrir una segunda conexión hacia él.

**Retrocompatibilidad:** una app que no conoce el tipo `0x07` no lo reconoce como canal (`unwrap` devuelve nil/null) y lo trata como audio crudo de grupo: son ~10-30 bytes, un clic imperceptible de pocos ms, sin fallo ni cierre de conexión. En Multipeer viaja en el contexto de invitación, que las apps viejas no leen.

**Timbre de conexión:** no es un paquete. Cada app lo genera localmente (2 notas ascendentes, Mi5→Si5, con envolvente, ~0.8 s, volumen ~0.3) cuando **ya había gente conectada** y se conecta alguien nuevo. Se sintetiza por código (sin assets) y sale por la ruta de audio activa sin abrir el micrófono ni cambiar la sesión.
