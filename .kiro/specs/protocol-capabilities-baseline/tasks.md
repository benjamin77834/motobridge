# Tareas: protocol-capabilities-baseline

Convención: cada tarea indica plataforma, criterio de terminado (CT) y pruebas. Ninguna tarea toca App Store ni la configuración de git.

- [ ] 1. Caracterizar y verificar el supuesto A1 (todas las plataformas)
  - [ ] 1.1 iOS: prueba XCTest que fija el parseo actual de presencia (`parsePresence`) con y sin `ALT`/`BAT`.
  - [ ] 1.2 Android: crear `android/app/src/test` y añadir JUnit como `testImplementation` en `build.gradle`. Prueba que fija el parseo actual de presencia (`BridgeController.kt:344-358` y la función que parsea).
  - [ ] 1.3 Mac: leer y probar el parseo de `RelaySession.swift:658` con líneas extra (prueba manual con el Mac Relay en marcha si no hay target de pruebas).
  - CT: se sabe y queda registrado en `PROTOCOL.md` si Android y Mac ignoran líneas desconocidas. Si alguno falla, se abre la rama del plan de riesgos (tolerancia primero).
  - Pruebas: las de 1.1 a 1.3.
  - _Requisitos: R2_

- [ ] 2. Vectores de prueba compartidos
  - [ ] 2.1 Crear `.kiro/specs/protocol-capabilities-baseline/vectors/presence-vectors.txt` con casos válidos, inválidos y límites (R1.5, R2.1 a R2.3).
  - CT: el archivo cubre cada criterio de R1 y R2; las tres suites lo consumen o lo copian.
  - _Requisitos: R1, R2_

- [ ] 3. Módulo de capacidades (lógica pura)
  - [ ] 3.1 iOS/Mac: `MotoBridge/Core/Network/PeerCapabilities.swift` con armado y parseo de `PV`, `ID`, `CAP`, tabla por vecino y por origen, consulta "todos soportan X" y contador legacy a 14 días. Agregarlo a `sources` del target MonoBridgeRelay en `project.yml`.
  - [ ] 3.2 Android: `net/PeerCapabilities.kt` con la misma lógica y las mismas reglas.
  - CT: los vectores de la tarea 2 pasan en iOS y Android; la tabla cumple R4.1 a R4.6.
  - Pruebas: XCTest y JUnit unitarias.
  - _Requisitos: R1, R4, R5_

- [ ] 4. Identificar al vecino emisor en el callback de recepción
  - [ ] 4.1 iOS: cambiar la firma de `onAudioData` en `AudioTransport.swift` y adaptar `PeerBridgeSession.swift`, `LocalNetworkTransport.swift`, `wireTransport` y `wireGatewayTransport`.
  - [ ] 4.2 Android: equivalente en `net/LocalNetworkTransport.kt` y `BridgeController.kt`.
  - [ ] 4.3 Mac: equivalente en `UniversalTransport.swift` y `RelaySession.swift` (Multipeer y UDP).
  - CT: R3.1 a R3.3; con la malla apagada y encendida el audio suena igual que en la baseline.
  - Pruebas: transporte simulado en XCTest y JUnit; prueba manual de audio en cada plataforma.
  - _Requisitos: R3_

- [ ] 5. Emitir y leer capacidades en la presencia
  - [ ] 5.1 iOS: `sendPresence` añade `PV`, `ID`, `CAP` (con `CAP` vacío en este spec salvo `TEST` en depuración); el parseo alimenta la tabla.
  - [ ] 5.2 Android: lo mismo en `BridgeController.kt`.
  - [ ] 5.3 Mac: lo mismo en `RelaySession.swift:408-415` y `:658`.
  - CT: R1.1 a R1.5 y R2.1 a R2.3 pasan en las tres plataformas; el radar no cambia de comportamiento.
  - Pruebas: vectores; prueba manual de radar con la build baseline y la nueva a la vez.
  - _Requisitos: R1, R2, R4, R5_

- [ ] 6. Contador de peers legacy y diagnóstico
  - [ ] 6.1 iOS: mostrar el contador en `AudioDiagnosticsView.swift`.
  - [ ] 6.2 Android y Mac: registrar el contador en el log local.
  - CT: R8.1; el contador no sale del dispositivo (revisión de código: sin llamadas de red nuevas).
  - Pruebas: unitaria de ventana de 14 días con reloj inyectado.
  - _Requisitos: R8_

- [ ] 7. Documentación y comentarios
  - [ ] 7.1 Reescribir `PROTOCOL.md` (§4 a §6, presencia, retiro de compatibilidad) y `KNOWN_LIMITATIONS.md`.
  - [ ] 7.2 Corregir los tres comentarios de código listados en R6.3 (solo comentarios).
  - CT: R6.1 a R6.4 y R8.2 a R8.4; el diff de 7.2 solo contiene comentarios.
  - _Requisitos: R6, R8_

- [ ] 8. Matriz de interoperabilidad contra la baseline
  - [ ] 8.1 Ejecutar las cuatro combinaciones de C1 y registrar resultados en `NETWORK_BRIDGE_TEST.md` (o en una sección nueva de `TEST_PLAN.md`).
  - CT: las cuatro combinaciones pasan; si una falla, el spec no se publica.
  - Pruebas: manual con dispositivos reales (iPhone, Android, Mac).
  - _Requisitos: R5, R7_
