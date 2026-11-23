# Tareas: mesh-smart-relay

Requiere los specs 1, 2 y 3 terminados.

- [ ] 1. Simulador de topologías y vectores
  - [ ] 1.1 iOS: simulador en memoria en `MotoBridgeTests` con las topologías de R4 (cadena de 4, estrella de 6, malla de 5, cadena de 7, mixta) y calidad y pérdida configurables.
  - [ ] 1.2 Android: el mismo simulador en `android/app/src/test` con los mismos vectores (archivo de texto compartido en `.kiro/specs/mesh-smart-relay/vectors/`).
  - CT: el simulador reproduce la baseline (inundación): 6, 20 transmisiones en las topologías de R4.1 y R4.3.
  - _Requisitos: R4_

- [ ] 2. Calidad de enlace y listas de vecinos
  - [ ] 2.1 iOS/Mac: `q` a partir del `LivenessTracker` (spec 2); armado y parseo de `NB` y `HRD`; tabla con antigüedad (`RelayPlanner.swift`, agregado a `project.yml` para Mac).
  - [ ] 2.2 Android: equivalente en `net/RelayPlanner.kt`.
  - [ ] 2.3 Añadir `NB` y `HRD` a la presencia solo con `SR` y límite de 256 bytes.
  - CT: R1.1 a R1.4; vectores de parseo pasan en las tres plataformas.
  - _Requisitos: R1_

- [ ] 3. Función de decisión de relay
  - [ ] 3.1 `decide` en iOS/Mac (compartida) y en Android con los pasos 1 a 7 y la histéresis.
  - [ ] 3.2 Reparación y falla abierta.
  - CT: R2.1 a R2.6, R3.1 a R3.3, R4.1 a R4.5 en el simulador; NF1 con banco unitario.
  - Pruebas: vectores y simulador.
  - _Requisitos: R2, R3, R4_

- [ ] 4. Envío dirigido en los transportes
  - [ ] 4.1 iOS: añadir envío a una lista de vecinos en `AudioTransport.swift`, `PeerBridgeSession.swift`, `LocalNetworkTransport.swift`.
  - [ ] 4.2 Android: `net/LocalNetworkTransport.kt`.
  - [ ] 4.3 Mac: `UniversalTransport.swift` y Multipeer en `RelaySession.swift`.
  - CT: prueba unitaria con transporte simulado que verifica que solo los vecinos pedidos reciben el paquete.
  - _Requisitos: R2, R6_

- [ ] 5. Integración con controladores y modo Auto
  - [ ] 5.1 iOS: sustituir los reenvíos de `wireTransport` y `wireGatewayTransport` por `decide` con TTL − 1; eliminar la heurística "más de 1 peer" (`NetworkBridgeController.swift:1081`).
  - [ ] 5.2 Android: sustituir la heurística de la coma en el nombre (`BridgeController.kt:396-399`).
  - [ ] 5.3 Mac: usar `decide` en `RelaySession.swift:490-491`.
  - [ ] 5.4 Activar `SR` en `CAP` solo cuando 5.1 a 5.3 estén terminadas.
  - CT: R6.1 a R6.3, R7.1, R7.2, R9.1 a R9.3.
  - Pruebas: unitaria del controlador con transportes simulados; matriz C1 con la baseline.
  - _Requisitos: R6, R7, R9_

- [ ] 6. Contadores y diagnóstico
  - [ ] 6.1 Contadores de R8.1 en iOS (`AudioDiagnosticsView.swift`), Android y Mac (log).
  - CT: R8.2; los contadores no salen del dispositivo.
  - _Requisitos: R8_

- [ ] 7. Pruebas de campo y revisión del TTL
  - [ ] 7.1 Cadena y estrella con 3 a 4 dispositivos físicos (iPhone, Android, Mac); anotar transmisiones, saltos y cortes de voz.
  - [ ] 7.2 Prueba mixta: cadena que llega a un hotspot compartido (R5.2).
  - [ ] 7.3 Con los datos, escribir la revisión del TTL en el README de specs (R8.3).
  - CT: R5.1, R5.2, R8.3 y resultados registrados en `TEST_PLAN.md`.
  - Pruebas: manual con dispositivos reales.
  - _Requisitos: R5, R8_

- [ ] 8. Documentación
  - [ ] 8.1 `PROTOCOL.md`: líneas `NB` y `HRD`, regla de relay, TTL 6.
  - CT: el documento describe el comportamiento real.
  - _Requisitos: R1, R2_
