# Tareas: voice-pipeline-opus-jitter

Cada tarea indica plataforma, criterio de terminado (CT) y pruebas. Requiere el spec 1 terminado.

- [ ] 1. Revisión previa
  - [ ] 1.1 Mac: leer `RelayAudio.swift` y declarar en este archivo si el Mac Relay reproduce audio (necesita jitter buffer) o solo reenvía (no lo necesita).
  - [ ] 1.2 iOS/Android: fijar con pruebas de caracterización el comportamiento actual de la cola de reproducción (`AudioIO.swift:227-268`, `audio/AudioIO.kt:213-229`).
  - CT: decisión de 1.1 escrita; pruebas de 1.2 en verde sobre la baseline.
  - _Requisitos: R5, R7_

- [ ] 2. Verificar control de Opus en iOS
  - [ ] 2.1 iOS: comprobar si `swift-opus` expone bitrate, complejidad, FEC y DTX; probar con una captura de 10 s y medir bytes por trama.
  - [ ] 2.2 Si no expone, añadir el adaptador C descrito en el diseño (decisión 4) en `project.yml`.
  - CT: se puede fijar y leer 24 000 bps; R2.1 pasa en iOS.
  - Pruebas: XCTest que codifica un tono y mide tamaño medio.
  - _Requisitos: R2_

- [ ] 3. Reempaquetador de captura a 20 ms
  - [ ] 3.1 iOS: cola circular tras la conversión a 16 kHz que emite bloques de 320 (`AudioIO.swift:124`).
  - [ ] 3.2 Android: pruebas que fijan los bloques de 320 (`audio/AudioIO.kt:127-158`); ajustar si fallan.
  - CT: R1.1 a R1.3.
  - Pruebas: unitarias con 1024, 480 y 441 muestras; conteo de paquetes en 10 s.
  - _Requisitos: R1_

- [ ] 4. Formato v2 y encuadre por vecino
  - [ ] 4.1 iOS: producir y parsear audio v2 (bit alto y secuencia) en `AudioIO.swift` y `AudioCodec.swift`; cabecera de malla siempre presente para vecinos `SEQ`; encuadre por vecino al enviar y al recibir en `NetworkBridgeController.swift`.
  - [ ] 4.2 Android: lo mismo en `audio/AudioIO.kt`, `net/MeshRelay.kt` y `BridgeController.kt`.
  - [ ] 4.3 Mac: encuadre por vecino y conversión a legacy al reenviar en `RelaySession.swift`.
  - [ ] 4.4 Activar el token `SEQ` en `CAP` en las tres plataformas solo al terminar 4.1 a 4.3.
  - CT: R3.1 a R3.5 y R7.1, R7.2.
  - Pruebas: unitarias de formato y conversión; matriz con baseline.
  - _Requisitos: R3, R7_

- [ ] 5. Selección de códec por grupo y Opus fiable
  - [ ] 5.1 iOS: parámetros Opus de la decisión 4; "preferir Opus" por defecto (`NetworkBridgeController.swift:161-166,579-582`); selección por tabla de orígenes con histéresis.
  - [ ] 5.2 Android: autoprueba de `MediaCodec` en `audio/OpusCodec.kt`; mismas reglas de selección.
  - [ ] 5.3 Mac: selección y conversión si el Mac Relay envía audio propio.
  - [ ] 5.4 Activar `OPUS` en `CAP` solo cuando la autoprueba pase.
  - CT: R2.1 a R2.3 y R4.1 a R4.4; la baseline con Opus apagado no recibe tramas Opus.
  - Pruebas: unitaria de selección con tablas simuladas; manual con la baseline como vecino y captura de bytes de códec.
  - _Requisitos: R2, R4_

- [ ] 6. Jitter buffer y ocultación de pérdida
  - [ ] 6.1 iOS/Mac: `JitterBuffer.swift` con la lógica de la decisión 6; PLC de Opus; reemplazar la cola de 6 buffers de `AudioIO.swift:227-268`.
  - [ ] 6.2 Android: `audio/JitterBuffer.kt` y ocultación por repetición atenuada; reemplazar la cola de 3 bloques (`audio/AudioIO.kt:213-229`).
  - [ ] 6.3 Contadores en diagnóstico (iOS) y en log (Android, Mac).
  - CT: R5.1 a R5.6 y R6.1 a R6.4.
  - Pruebas: unitarias con reloj falso (pérdida, reorden, duplicado, tardía, desborde, ráfaga); manual con pérdida simulada del 5 %.
  - _Requisitos: R5, R6_

- [ ] 7. Medición de latencia y CPU
  - [ ] 7.1 Documentar en `TEST_PLAN.md` el método de latencia boca a oído y ejecutar 20 mediciones con 1 salto.
  - [ ] 7.2 Medir CPU en iPhone 11 (modelo más antiguo soportado por iOS 26) y comparar con la baseline.
  - CT: R8.1 y NF1 cumplidos o desviaciones documentadas en el README con propuesta.
  - Pruebas: manual con dispositivos reales.
  - _Requisitos: R8, NF1_

- [ ] 8. Documentación y publicación
  - [ ] 8.1 Actualizar `PROTOCOL.md` §4 y §5 con el formato v2 y el algoritmo de elección de códec.
  - [ ] 8.2 Ejecutar la matriz C1 con la baseline y 10 min de conversación por combinación.
  - CT: R7.3 sin crashes ni ruido en la baseline; las cuatro combinaciones pasan.
  - _Requisitos: R7_
