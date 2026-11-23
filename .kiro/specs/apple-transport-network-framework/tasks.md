# Tareas: apple-transport-network-framework

Requiere los specs 1 a 4 terminados. Las tareas modifican proyectos (`project.yml`) y no tocan App Store ni la configuración de git.

- [ ] 1. Preparación y prototipo de la API de iOS 26
  - [ ] 1.1 Comprobar con `xcodebuild -version` y en Xcode qué versión usa el build real (A2) y que no hay `SWIFT_TREAT_WARNINGS_AS_ERRORS` en los targets (R1.4).
  - [ ] 1.2 iOS: prototipo aislado (target o archivo de prueba, no se integra) con `NetworkListener` + Bonjour `_motobridge._udp` + `NetworkBrowser` + `NetworkConnection` UDP y P2P incluido entre dos iPhones físicos; cierra las dudas de firma y de entrega de datagramas listadas en el diseño (decisión 3).
  - [ ] 1.3 Probar que un Android (build actual) descubre al iPhone con el listener nuevo y viceversa.
  - CT: documento breve en este directorio (`prototype-notes.md`) con firmas verificadas y resultados; el prototipo manda y recibe datagramas de 100 bytes entre iPhone↔iPhone y iPhone↔Android.
  - _Requisitos: R1.4, R2_

- [ ] 2. Subir mínimos
  - [ ] 2.1 `project.yml`: iOS 26.0 y macOS 26.0 (el target watchOS sigue desactivado).
  - [ ] 2.2 Eliminar ramas de compatibilidad con iOS 17 a 25 y comprobar que el build compila con Xcode 27.
  - [ ] 2.3 Documentación: `README.md`, `KNOWN_LIMITATIONS.md` y texto de tienda si cita el mínimo, con la tabla de iPhone XS, XS Max y XR.
  - CT: R1.1 a R1.4; el usuario revisa la advertencia de dispositivos afectados.
  - _Requisitos: R1_

- [ ] 3. Transporte Network (iOS y Mac)
  - [ ] 3.1 `NetworkFrameworkTransport.swift` con listener, navegador y conexiones UDP; datagramas; tope de vecinos; desempate por `ID`; liveness por conexión; recreación con retroceso.
  - [ ] 3.2 Verificar que `NetworkBrowser` reevalúa al reaparecer un servicio (R6.2); si no, implementar el reinicio a los 5 s.
  - [ ] 3.3 Nombre de servicio con sufijo de `ID`; verificar que Android y la baseline no muestran el sufijo.
  - [ ] 3.4 Archivo compartido con el target Mac en `project.yml`.
  - CT: R2.1 a R2.5 usando solo este camino; el camino viejo `LocalNetworkTransport.swift` ya no se usa.
  - Pruebas: unitaria con dos instancias por loopback; manual con dispositivos.
  - _Requisitos: R2, R6_

- [ ] 4. Transporte compuesto y selector de camino
  - [ ] 4.1 `PathSelector.swift` (lógica pura) con las reglas de la decisión 5.
  - [ ] 4.2 `MultiPathTransport.swift` con tabla `ID → caminos`, asociación provisional, deduplicación única y envío por camino.
  - [ ] 4.3 Aislar Multipeer en su clase de camino (`PeerBridgeSession.swift`), corrigiendo los comentarios de Bluetooth y `.reliable`.
  - [ ] 4.4 Ampliar la caché de vistos si R5.5 lo exige.
  - CT: R3.1 a R3.4, R4.1 a R4.7, R5.1 a R5.6.
  - Pruebas: las unitarias de la sección de testabilidad del diseño.
  - _Requisitos: R3, R4, R5, R8.2_

- [ ] 5. Integrar en el controlador y en la UI (iOS)
  - [ ] 5.1 Reemplazar `transport` y `gatewayTransport` por el compuesto; eliminar `wireGatewayTransport` y el puente (`NetworkBridgeController.swift:1073-1150`, `:1278-1284`).
  - [ ] 5.2 Mostrar en eventos y en la vista el estado por camino (activo, caído, no disponible).
  - [ ] 5.3 Mantener los modos `.apple` y `.universal` como ajuste de depuración.
  - CT: R3.3, R4.5; el radar muestra una entrada por vecino; los tests de `MotoBridgeTests` pasan.
  - _Requisitos: R3, R4_

- [ ] 6. Android
  - [ ] 6.1 Anunciar `DP` en `CAP`, usar `ID` y verificar deduplicación única (`net/MeshRelay.kt`, `BridgeController.kt`).
  - [ ] 6.2 Interoperabilidad con listener y navegador nuevos de iOS: descubrimiento en ambos sentidos, reconexión tras apagar el Wi-Fi (R6.1) y 10 min de audio sin eco (R7.3).
  - [ ] 6.3 Manejar un iPhone que aparece dos veces (misma `ID`, dos IP) conservando la conexión más reciente.
  - CT: R7.1 con Android baseline y Android nuevo; sin crashes (recordar el fix de FGS del commit `f494455`, no tocar `BridgeService.kt` salvo necesidad).
  - Pruebas: unitaria de asociación por `ID`; manual con dispositivos.
  - _Requisitos: R3, R7_

- [ ] 7. Mac Relay
  - [ ] 7.1 Sustituir `UniversalTransport.swift` y el Multipeer propio de `RelaySession.swift` por el compuesto compartido; mantener `beginActivity`.
  - [ ] 7.2 `MonoBridgeRelay/Info.plist` sin quitar servicios; `project.yml` con los archivos compartidos y macOS 26.
  - [ ] 7.3 Aplicar la misma regla de relay del spec 4 al puente entre caminos.
  - CT: R7.1 con Mac nuevo y baseline; el relay reenvía entre caminos sin duplicar (R5.3).
  - _Requisitos: R3, R5, R7_

- [ ] 8. Pruebas de conmutación, rejoin y segundo plano
  - [ ] 8.1 Apagar un camino con voz en curso y medir la interrupción (R4.2 y R4.3).
  - [ ] 8.2 Rejoin con 10 repeticiones por combinación (R6.1).
  - [ ] 8.3 Añadir el camino Network con iOS 26 a la matriz de segundo plano del spec 2 y actualizar `backgroundPathPreference` (R6.3, R4.7).
  - [ ] 8.4 CPU en iPhone 11 con dos caminos (NF1).
  - CT: resultados anotados en `TEST_PLAN.md` y `KNOWN_LIMITATIONS.md`.
  - Pruebas: manual con dispositivos reales.
  - _Requisitos: R4, R6, NF1_

- [ ] 9. Interoperabilidad y publicación en TestFlight
  - [ ] 9.1 Matriz C1 completa (R7.1 a R7.3).
  - [ ] 9.2 Actualizar `PROTOCOL.md`, `CHANGELOG.md` y registrar la fecha de partida del contador de retiro de compatibilidad (spec 1 R8) y las condiciones de retiro de Multipeer (R8.1).
  - CT: las combinaciones pasan; el usuario aprueba por escrito antes de publicar.
  - _Requisitos: R7, R8_
