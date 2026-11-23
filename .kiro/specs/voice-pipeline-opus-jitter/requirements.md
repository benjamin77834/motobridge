# Requisitos: voice-pipeline-opus-jitter

## Objetivo

Que la voz viaje en Opus de 24 kbps en paquetes de 20 ms con número de secuencia, y que el receptor la reproduzca con un jitter buffer de 60 a 120 ms que descarta lo que llega tarde y oculta lo que se perdió. Aplica a iOS, Android y Mac Relay. Es la causa raíz más probable de cortes y de audio entrecortado, y es requisito de los specs 4 y 5 (secuencia y cabecera de malla siempre presente).

## Dependencias

- Spec 1 `protocol-capabilities-baseline` (capacidades `SEQ` y `OPUS`, id de vecino en recepción, tabla por origen).
- No depende del spec 2 en lo técnico; se prueba mejor después.

## Origen y supuestos

- Entrada: estudio §2 sección B y riesgo 3. Datos del código: Opus apagado por defecto (`NetworkBridgeController.swift:161-166,579-582`); iOS no fija bitrate (`OpusCodec.swift`); Android fija 24000 (`audio/OpusCodec.kt:34-36`); captura iOS con tap de 1024 muestras sin reempaquetar (`AudioIO.swift:124`); iOS descarta el paquete nuevo si ya hay 6 en cola (`AudioIO.swift:266-268`) y Android descarta el viejo con cola de 3 (`audio/AudioIO.kt:221-223`); el paquete de audio es `[codec][payload]` sin secuencia (`AudioIO.swift:213-216`).
- Hecho del código: la voz va a 16 kHz mono (`AudioIO.swift:22`, `audio/AudioIO.kt:22`) y no a 8 kHz como decía `PROTOCOL.md`.
- Hecho del código: el comentario del controlador avisa que Opus puede **crashear** si llega audio no-Opus o viceversa (`NetworkBridgeController.swift:161-163`). Por eso la elección del códec es del grupo entero, no del par (ver diseño).
- Supuesto A1: bitrate fijo de 24 kbps. El usuario no respondió la pregunta de bitrate adaptativo; se deja el adaptativo en backlog.
- Supuesto A2: latencia extremo a extremo propuesta, a validar con el usuario: ≤ 250 ms con 1 salto y ≤ 400 ms con 3 saltos. Son metas propuestas, no medidas.
- Supuesto A3: `RelayAudio.swift` del Mac Relay se revisa en la tarea 1; si solo reenvía paquetes y no reproduce, el jitter buffer no aplica en Mac y se declara.

## Requisitos funcionales (EARS)

### R1. Paquetes de 20 ms exactos

CUANDO el micrófono captura audio, EL SISTEMA DEBERÁ emitir bloques de exactamente 320 muestras a 16 kHz (20 ms) hacia el codificador, sin depender del tamaño del bloque que entrega el sistema.

Criterios de aceptación:
1. R1.1 En una captura de 10 s, el número de paquetes de voz generados está entre 495 y 505 en iOS y Android.
2. R1.2 Ningún paquete de voz transporta un número de muestras distinto de 320 (prueba unitaria sobre el reempaquetador con bloques de entrada de 1024, 480 y 441 muestras).
3. R1.3 El reempaquetador no acumula más de 1 bloque de retardo adicional (20 ms) en estado estable.

### R2. Opus de 24 kbps y bandera de sesión de Opus fiable

EL SISTEMA DEBERÁ codificar con Opus a 24 kbps, 16 kHz, mono, aplicación de voz, con FEC y DTX desactivados, y DEBERÁ anunciar el token `OPUS` solo si una autoprueba de codificar y decodificar una trama de 20 ms funciona.

Criterios de aceptación:
1. R2.1 El tamaño medio de una trama Opus en una captura de 10 s de voz está entre 40 y 90 bytes (24 kbps ≈ 60 bytes por 20 ms con variación de VBR).
2. R2.2 Si la autoprueba falla (en particular en Android con `MediaCodec`), el nodo no anuncia `OPUS`, usa PCM y registra un evento.
3. R2.3 iOS permite fijar bitrate de forma explícita. La tarea 2 verifica si `swift-opus` lo expone; si no, se añade un adaptador (ver diseño).

### R3. Número de secuencia de audio y cabecera de malla siempre presente (formato v2)

CUANDO un vecino directo declara `SEQ`, EL SISTEMA DEBERÁ enviarle voz con cabecera de malla de 9 bytes siempre presente (aunque la opción de malla esté apagada) y con un número de secuencia de audio de 16 bits dentro del paquete de audio.

Criterios de aceptación:
1. R3.1 El paquete v2 tiene este orden: cabecera de malla (9 bytes), encabezado de canal (6 bytes, `VoiceChannel`), byte de códec con bit alto activo, secuencia de 2 bytes big-endian, carga útil.
2. R3.2 La secuencia de audio aumenta en 1 por cada trama de voz de un origen y da la vuelta de 65535 a 0 sin afectar la reproducción (prueba unitaria con aritmética de serie).
3. R3.3 Un vecino sin `SEQ` recibe el formato que su ajuste de malla implique en la baseline, sin bit alto ni secuencia.
4. R3.4 Con un vecino `SEQ` y otro legacy en el mismo nodo, ambos reproducen la voz del nodo (C1).
5. R3.5 Un paquete v2 reenviado a un vecino legacy se convierte al formato legacy (se quita el bit alto y la secuencia) antes de enviarse; el relay no reenvía formato v2 a un vecino sin `SEQ`.

### R4. Códec elegido por el grupo

EL SISTEMA DEBERÁ usar Opus solo si todos los orígenes conocidos (vistos en los últimos 30 s) y todos los vecinos directos declaran `OPUS`; en cualquier otro caso DEBERÁ usar PCM.

Criterios de aceptación:
1. R4.1 Con un grupo de dos nodos nuevos con `OPUS`, la voz sale en Opus.
2. R4.2 Cuando se conecta un vecino sin capacidades conocidas todavía, el nodo cambia a PCM en menos de 500 ms después de la conexión y vuelve a Opus como mínimo 10 s después de que no quede ningún nodo sin `OPUS`.
3. R4.3 Una build baseline con Opus apagado en el grupo no recibe nunca una trama Opus (prueba con la baseline como receptor y registro de bytes de códec enviados).
4. R4.4 El ajuste de usuario de Opus cambia de significado: "preferir Opus" (activado por defecto). El resultado efectivo lo decide R4.

### R5. Jitter buffer con descarte de lo tardío

CUANDO llega una trama de voz v2, EL SISTEMA DEBERÁ colocarla en un jitter buffer por origen y reproducirla en orden con un retardo objetivo de entre 60 y 120 ms; SI llega después de su momento de reproducción, ENTONCES EL SISTEMA DEBERÁ descartarla sin reintento.

Criterios de aceptación:
1. R5.1 El retardo objetivo inicial es 60 ms y se mueve entre 60 y 120 ms en pasos de 20 ms: sube 20 ms cuando más del 5 % de las tramas de los últimos 2 s llegaron tarde, y baja 20 ms tras 10 s sin tardías.
2. R5.2 Una trama con secuencia anterior al cursor de reproducción se descarta y se cuenta como `tardía`.
3. R5.3 Una trama que llega fuera de orden dentro de la ventana se reproduce en su sitio (prueba con permutación de 3 tramas consecutivas).
4. R5.4 Con la profundidad por encima del objetivo más 40 ms, el buffer descarta las tramas más antiguas hasta volver al objetivo (política unificada en iOS y Android).
5. R5.5 Tras 200 ms sin tramas de un origen (fin de ráfaga de push-to-talk), el buffer se vacía y la siguiente trama arranca una ráfaga nueva con 60 ms de prellenado.
6. R5.6 Los mismos contadores `tardías`, `perdidas`, `ocultadas`, `descartadas por desborde` existen en iOS y Android y se muestran en diagnóstico.

### R6. Ocultación de pérdida

CUANDO falta una trama en el momento de reproducirla y la siguiente aún no llegó o ya llegó, EL SISTEMA DEBERÁ ocultar la pérdida en lugar de dejar un hueco, durante como máximo 5 tramas consecutivas (100 ms).

Criterios de aceptación:
1. R6.1 iOS: con Opus se usa la ocultación de pérdida del decodificador; con PCM se rellena con silencio.
2. R6.2 Android: sin API de ocultación en `MediaCodec`, se repite la última trama decodificada atenuada a 50 % y se pasa a silencio tras 3 tramas.
3. R6.3 Con pérdida aleatoria simulada del 5 % y variación de llegada de ±30 ms, el 100 % de las pérdidas aisladas se ocultan y no hay huecos de silencio mayores de 40 ms por pérdida aislada (medido en el diagnóstico del reproductor).
4. R6.4 Más de 5 tramas consecutivas perdidas generan silencio hasta que llegue una trama nueva, sin ruido.

### R7. Compatibilidad con la baseline

EL SISTEMA DEBERÁ conservar C1 a C4 durante la transición.

Criterios de aceptación:
1. R7.1 Las cuatro combinaciones de C1 con una build baseline en el grupo (iOS↔iOS, iOS↔Android, iOS↔Mac, Android↔Android) tienen audio bidireccional en PCM.
2. R7.2 Ningún paquete v2 llega a un vecino sin `SEQ`. Prueba de captura en el vecino baseline: ningún byte de códec con bit alto.
3. R7.3 Sin crashes ni ruido blanco en el nodo baseline al hablar el nodo nuevo, durante 10 min de conversación.

### R8. Latencia

Criterios de aceptación:
1. R8.1 La latencia boca a oído (captura a reproducción) con 1 salto es ≤ 250 ms en el percentil 90 de 20 mediciones (meta propuesta; ver pregunta abierta).
2. R8.2 Con 3 saltos (spec 4 en marcha) es ≤ 400 ms en p90.
3. R8.3 El método de medida (tono de referencia y grabación de ambos extremos) queda documentado en `TEST_PLAN.md`.

## Requisitos no funcionales

- NF1. El uso de CPU del reempaquetador, codificador y jitter buffer no sube más de 10 puntos porcentuales respecto a la baseline en un iPhone 11 (el modelo más antiguo soportado por iOS 26).
- NF2. Memoria del jitter buffer acotada: máximo 10 tramas por origen y 8 orígenes simultáneos.

## Fuera de alcance

- Bitrate adaptativo según calidad de enlace (backlog, pregunta 17 del estudio).
- FEC en banda y DTX (se revisarán con datos de campo).
- Cifrado del audio.
- Relay selectivo (spec 4) y retransmisión de paquetes perdidos (nunca).
