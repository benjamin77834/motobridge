# Diseño: voice-pipeline-opus-jitter

## Visión general

El audio actual viaja como `[códec][carga]` dentro de un encabezado de canal y, si la malla está encendida, dentro de una cabecera de malla. No tiene secuencia ni marca de tiempo, y los dos extremos usan políticas opuestas para la cola de reproducción. Este spec introduce el formato v2 para pares que declaran `SEQ`: la cabecera de malla (que ya trae `originId` y `packetId`) pasa a estar siempre presente y se añade una secuencia de audio de 16 bits dentro del paquete de audio. Sobre ese formato se construyen un reempaquetador de 20 ms, Opus a 24 kbps, un jitter buffer por origen y ocultación de pérdida. La elección de Opus es decisión del grupo para evitar los crashes de decodificación mixta.

**Stack:** Swift/SwiftUI con `AVAudioEngine` y la librería `swift-opus` (ya en `project.yml`) en iOS y Mac; Kotlin con `AudioRecord`/`AudioTrack` y `MediaCodec` en Android. Sin dependencias nuevas salvo que la verificación de la tarea 2 exija un adaptador C pequeño (ver decisión 4). Deployment target sin cambios en este spec.

## Decisión 1: dónde va la secuencia

Hay que separar dos números:
- `packetId` de la cabecera de malla: único por paquete de cualquier tipo del origen (presencia, texto, voz). Sirve para deduplicar.
- Secuencia de audio: cuenta solo tramas de voz y es lo que necesita el jitter buffer. Si se usara `packetId` para ordenar, cada presencia entre tramas de voz parecería una pérdida.

**Elegido:** secuencia de audio de 16 bits en el paquete de audio, marcada por el bit alto del byte de códec.

| Capa | Campos (big-endian) |
|---|---|
| Cabecera de malla (9 B) | `originId` (4), `packetId` (4), `ttl` (1) |
| Encabezado de canal (6 B) | magia `V`, tipo, `targetId` (4) |
| Audio v2 | byte de códec con bit 7 activo (0x80 = PCM, 0x81 = Opus), secuencia (2 B), carga |
| Audio legacy | byte de códec (0x00 = PCM, 0x01 = Opus), carga |

La secuencia de 16 bits a 20 ms da la vuelta cada 21,8 min; se compara con aritmética de serie, así que no importa.

Alternativas descartadas:
- *Usar `packetId` de 32 bits para ordenar*: huecos falsos por presencia y texto (ver arriba).
- *Cabecera RTP completa (12 B)*: más ancha y no aporta nada que el `originId` más la secuencia ya den.
- *Marca de tiempo además de secuencia*: con tramas de 20 ms fijas, el tiempo se deduce de la secuencia. Menos bytes.

## Decisión 2: cabecera de malla siempre presente con pares `SEQ`

La baseline obliga a que la malla esté igual en todos y receptores sin cabecera confunden paquetes con cabecera (`NetworkBridgeController.swift:858-862`). Con la identificación de vecino del spec 1, el receptor sabe por vecino qué encuadre usar:

| Estado del vecino | Encuadre esperado de él |
|---|---|
| Declara `SEQ` | v2, siempre con cabecera de malla |
| Sin `SEQ`, ajuste local de malla encendido | baseline con cabecera |
| Sin `SEQ`, ajuste local de malla apagado | baseline directo sin cabecera |
| Capacidades aún desconocidas | baseline según el ajuste local |

Esto da deduplicación por `originId` + `packetId` en todos los caminos aunque la opción de malla esté apagada, que es la base del spec 5 (dos caminos al mismo vecino). No cambia el significado de la opción de malla para vecinos legacy.

Alternativa descartada: *marcar el formato con una magia nueva al inicio del paquete*. La cabecera de malla empieza con un `originId` aleatorio, así que ningún primer byte queda libre. La identificación por vecino evita el problema.

## Decisión 3: códec decidido por el grupo

El comentario del código advierte que un receptor con Opus apagado puede crashear al recibir una trama Opus. Un relay reenvía lo que recibió sin transcodificar, así que una trama Opus de un origen puede llegar a un nodo legacy lejano que el origen no ve.

**Elegido:** Opus solo si todos los orígenes conocidos (tabla por origen del spec 1, vistos en 30 s) y todos los vecinos directos declaran `OPUS`; si no, PCM. Se cambia a PCM en menos de 500 ms tras conectar un vecino de capacidades desconocidas, y se vuelve a Opus tras 10 s sin nodos sin `OPUS` (histéresis para evitar vaivén). Cada trama lleva su códec en el byte, así que el cambio en medio de una ráfaga es seguro para quien soporta ambos.

Alternativas descartadas:
- *Códec decidido por vecino*: el relay no puede garantizar que el siguiente salto lo entienda.
- *Transcodificación en cada relay*: duplica CPU y latencia y degrada calidad por doble codificación.
- *Mantener Opus apagado por defecto*: pierde el beneficio de 16 a 24 kbps frente a PCM de 256 kbps (16 kHz, 16 bits).

Conversión de formato al reenviar a un vecino legacy (R3.5): se quita el bit alto del códec y la secuencia; la carga no cambia. Si la carga es Opus y el vecino no declara `OPUS`, no se reenvía (por R4 el origen no debería haber enviado Opus, así que es un caso de defensa) y se cuenta como `descartada por compatibilidad`.

## Decisión 4: Opus y bitrate por plataforma

**iOS/Mac:** `swift-opus` ya se usa. Verificar en la tarea 2 si su interfaz permite fijar bitrate. `opus_encoder_ctl` es una función C variádica y Swift no puede llamar funciones variádicas de C, así que si el paquete no lo expone, se añade un adaptador C mínimo (un target C en `project.yml` que envuelva `OPUS_SET_BITRATE`, `OPUS_SET_COMPLEXITY`, `OPUS_SET_INBAND_FEC` y `OPUS_SET_DTX`). Parámetros: 24 000 bps, VBR restringido, complejidad 5, aplicación de voz, FEC apagado, DTX apagado.

**Android:** se conserva `MediaCodec` porque ya fija 24 000 (`audio/OpusCodec.kt:34-36`). Se añade una autoprueba al arrancar (codificar y decodificar una trama de 20 ms de un tono) y solo si pasa se anuncia `OPUS`.

Alternativas descartadas para Android:
- *libopus por JNI (NDK)*: añade toolchain nativa al build y APKs por ABI; mucho coste para el alcance de este spec.
- *Concentus (Java puro)*: dependencia nueva con rendimiento incierto en el dispositivo más lento del grupo. Se reconsidera si la autoprueba falla en muchos fabricantes.

FEC y DTX apagados: FEC sube el bitrate; DTX en push-to-talk crea silencios que el jitter buffer ya maneja con su regla de 200 ms. Se revisan con datos de campo.

## Decisión 5: reempaquetador de captura

La captura iOS entrega tramas con `installTap(bufferSize: 1024)` a la tasa del hardware (`AudioIO.swift:124`), luego se convierte a 16 kHz. Se añade una cola circular de Int16 después de la conversión que emite bloques de exactamente 320 muestras; el resto queda en la cola. Android ya acumula bloques de 320 (`audio/AudioIO.kt:127-158`) y solo necesita pruebas que fijen el comportamiento.

## Decisión 6: jitter buffer por origen

Lógica pura (reloj y decodificador inyectados), una clase por plataforma con el mismo comportamiento:

- Clave: `originId` (de la cabecera de malla) para vecinos v2. Para legacy, la clave es el id de vecino y no hay reordenación (se reproduce en orden de llegada con la política unificada de desborde).
- Cursor de reproducción: secuencia de la próxima trama a reproducir. Primera trama de una ráfaga fija el cursor y espera el retardo objetivo (60 ms) antes de arrancar.
- Trama con secuencia menor que el cursor: descartada como tardía.
- Trama con secuencia mayor que el cursor: se guarda hasta su turno.
- Turno sin trama: se oculta (decodificador con pérdida en iOS con Opus; silencio en PCM; repetición atenuada en Android) hasta 5 tramas seguidas, luego silencio.
- Retardo objetivo adaptativo: sube 20 ms si más del 5 % de las tramas de los últimos 2 s llegaron tarde, baja 20 ms tras 10 s sin tardías, siempre entre 60 y 120 ms.
- Desborde: si la profundidad supera objetivo + 40 ms, se descartan las más antiguas.
- Fin de ráfaga: 200 ms sin tramas vacía y reinicia.
- Mezcla: la salida de cada origen se suma en el nodo de reproducción existente; se limita a 8 orígenes (NF2) y se ignora el más antiguo si hay más.

Por qué un retardo de 60 a 120 ms: 60 ms (3 tramas) cubre la variación típica de Wi-Fi directo; 120 ms es el límite de latencia añadida que se acepta para voz en moto. Son los valores del usuario y la meta de la tarea 8 los revisa con medidas.

Alternativas descartadas:
- *Buffer fijo de 60 ms*: no se adapta a hotspots con más variación.
- *Descartar lo nuevo cuando está lleno (iOS hoy)*: aumenta el retraso acumulado. Se descarta lo viejo.
- *Reintentos de tramas perdidas*: contra el requisito (lo tardío se descarta) y sube la latencia.

## Archivos a modificar

- iOS: `Core/Audio/AudioIO.swift` (reempaquetado, formato v2, jitter, `:124`, `:213-216`, `:227-234`, `:266-268`), `Core/Audio/OpusCodec.swift` (bitrate, PLC), `Core/Audio/AudioCodec.swift` (byte con bit alto), nuevo `Core/Audio/JitterBuffer.swift`, `NetworkBridgeController.swift` (`opusEnabled` pasa a "preferir", elección por grupo, `:161-166,579-582`, envío por vecino, recepción por encuadre), `project.yml` (adaptador C si hace falta), `AudioDiagnosticsView.swift` (contadores).
- Android: `audio/AudioIO.kt` (jitter y política, `:213-229`), `audio/OpusCodec.kt` (autoprueba), nuevo `audio/JitterBuffer.kt`, `net/MeshRelay.kt` y `BridgeController.kt` (encuadre por vecino).
- Mac: `RelayAudio.swift` (si reproduce, usar `JitterBuffer.swift`), `RelaySession.swift` (encuadre por vecino y conversión al reenviar), `project.yml` (agregar `JitterBuffer.swift` si aplica).
- Docs: `PROTOCOL.md` §4 y §5 (formato v2).

## Manejo de errores

| Operación | Falla | Tipo | El llamador recibe | Log |
|---|---|---|---|---|
| Autoprueba de Opus | Falla en `MediaCodec` o codificador | Recuperable | Nodo sin `OPUS`; PCM para todo el grupo | `warning` una vez por arranque |
| Codificar trama | Excepción del codificador | Recuperable | Esa trama se pierde; tras 3 seguidas el nodo cae a PCM 30 s | `warning` |
| Decodificar trama | Datos corruptos o códec desconocido | Recuperable | Trama descartada y contada; nunca crash | `debug` con contador |
| Trama v2 con carga de longitud 0 o mayor de 400 bytes | Inválida | Recuperable | Descartada | `debug` |
| Secuencia repetida | Duplicado | Recuperable | Descartada por la deduplicación de malla o por el cursor | contador |
| Reempaquetador | Desbordamiento de cola (más de 2 s acumulados) | Recuperable | Se descarta lo más antiguo y se reinicia | `warning` |
| Vecino sin capacidades pero llega trama con bit alto | Inconsistencia | Recuperable | Se procesa como v2 y se marca al vecino `SEQ` provisional | `info` |
| Sesión de audio perdida | Interrupción | Recuperable | Ver spec 2 | `warning` |

Ningún error es fatal para la app. El peor caso es PCM sin ocultación, es decir, la baseline.

## Validación de entradas externas

| Entrada | Obligatoria | Tipo y límite | Si falla |
|---|---|---|---|
| Byte de códec | Sí | 0x00, 0x01, 0x80, 0x81 | Descartar paquete |
| Secuencia | Sí en v2 | Entero sin signo de 16 bits | n/a |
| Longitud de carga PCM | Sí | Exactamente 640 bytes por trama de 20 ms (con el valor legacy que ya exista, hasta 4096) | Descartar |
| Longitud de carga Opus | Sí | 1 a 400 bytes | Descartar |
| `originId` | Sí en v2 | 1 a 4 294 967 295 | Descartar si es 0 |

## Invariantes

- **Opus solo se envía si el grupo lo soporta.** La aplica la función de selección de códec del controlador porque es el único punto con la tabla por origen del spec 1.
- **El formato v2 no sale hacia un vecino sin `SEQ`.** La aplica la capa de envío por vecino, no el codificador, porque el codificador produce una sola trama para todos y la conversión se hace por vecino al armar el paquete.
- **Una trama tardía nunca se reproduce.** La aplica el jitter buffer, porque es la única capa con el cursor.
- **El jitter buffer no crece sin límite.** Lo aplica el propio buffer (NF2).

## Testabilidad

Unitarias:
- Reempaquetador con entradas de 1024, 480 y 441 muestras: siempre bloques de 320.
- Formato v2: armado y parseo, vuelta de 65535 a 0, conversión a legacy.
- Jitter buffer con reloj falso y secuencias generadas: pérdida, reordenación, duplicados, tardías, desborde, fin de ráfaga, 5 % de pérdida.
- Selección de códec por grupo con una tabla simulada.
- Autoprueba de Opus con un codificador simulado que falla.

Integración (dispositivos): la matriz C1, 10 min con la baseline de vecino y captura de bytes de códec.
Campo: latencia (R8), escucha con pérdida simulada y en carretera (con un tercero que valore la inteligibilidad), uso de CPU en iPhone 11 (NF1).
