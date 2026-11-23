# Tareas: link-liveness-heartbeat

Cada tarea indica plataforma, criterio de terminado (CT) y pruebas. Requiere el spec 1 terminado.

- [ ] 1. Rastreador de liveness (lógica pura)
  - [ ] 1.1 iOS/Mac: `MotoBridge/Core/Network/LivenessTracker.swift` con estados `desconocido`/`vivo`/`caído`/`inestable`, reloj inyectado, constantes `downAfter`=2 s, `upAfterPackets`=2 en 1,5 s. Agregarlo a `sources` de MonoBridgeRelay en `project.yml`.
  - [ ] 1.2 Android: `net/LivenessTracker.kt` con las mismas reglas.
  - CT: pruebas de R2.1 a R2.4 y R3.1, R3.2 con reloj falso pasan en XCTest y JUnit.
  - _Requisitos: R2, R3_

- [ ] 2. Keepalive de 500 ms a pares `HB`
  - [ ] 2.1 iOS: temporizador único por transporte (Multipeer y UDP), armado por vecino según su encuadre, solo a vecinos con `HB`; activar el token `HB` en `CAP`.
  - [ ] 2.2 Android: equivalente en `net/LocalNetworkTransport.kt` y `BridgeController.kt`; activar `HB`.
  - [ ] 2.3 Mac: equivalente en `UniversalTransport.swift` y `RelaySession.swift` (Multipeer y UDP); activar `HB`.
  - CT: R1.1 a R1.4 y R5.2; con una build baseline en el grupo nadie oye clics ni ve riders fantasma.
  - Pruebas: unitaria de armado y de TTL de malla 1; manual en cadena de 3 nodos (iPhone, Mac, Android).
  - _Requisitos: R1, R5_

- [ ] 3. Eventos de caída y recuperación hacia el controlador
  - [ ] 3.1 iOS: extender `AudioTransport.swift` con eventos de liveness; `NetworkBridgeController` los usa para sacar al vecino del relay y del radar; reemplazar el temporizador de 7 s del radar (`:726-733`) por el estado de liveness para vecinos `HB`.
  - [ ] 3.2 Android: lo mismo en `BridgeController.kt`.
  - [ ] 3.3 Mac: lo mismo en `RelaySession.swift`.
  - CT: R2.1, R2.3, R2.5; la tolerancia de 30 s de Android y Mac queda solo para vecinos sin `HB`.
  - Pruebas: simulación con dos transportes en proceso; manual: apagar Wi-Fi de un teléfono.
  - _Requisitos: R2_

- [ ] 4. Reconexión con retroceso y desempate
  - [ ] 4.1 iOS Multipeer: sustituir el retraso fijo de `PeerBridgeSession.swift:236` por retroceso 1/2/4/5 s con cancelación por evento de descubrimiento; conservar `shouldInvite`.
  - [ ] 4.2 iOS UDP: añadir reintento propio con desempate por `ID` y respaldo a los 5 s en `LocalNetworkTransport.swift`.
  - [ ] 4.3 Android y Mac UDP: equivalente (desempate por `ID`, retroceso, cancelación por evento de NSD o Bonjour).
  - [ ] 4.4 Respetar `autoConnect` apagado (R4.5) y detenido por el usuario (R4.4).
  - CT: R4.1 a R4.5; 10 repeticiones por combinación (iPhone↔iPhone, iPhone↔Android, iPhone↔Mac) con p90 ≤ 8 s, registrado en `TEST_PLAN.md`.
  - Pruebas: unitaria de la calculadora de retroceso y del desempate; campo.
  - _Requisitos: R4_

- [ ] 5. Ciclo de vida y segundo plano
  - [ ] 5.1 iOS: tras interrupción de audio, reactivar sesión, reiniciar motor y reconectar; al volver a primer plano, reiniciar navegadores Multipeer y Bonjour.
  - [ ] 5.2 iOS: prueba automatizada que protege `isIdleTimerDisabled` (true con bridge activo, false al detener).
  - [ ] 5.3 Android: verificar que el reinicio del servicio por el sistema reconecta; revisar `BridgeService.kt` con el último fix de FGS (commit `f494455`) sin romperlo.
  - [ ] 5.4 Mac: comprobar que `beginActivity` se mantiene mientras el bridge está activo con la ventana oculta.
  - CT: R6.1 a R6.5.
  - Pruebas: unitaria del manejador de interrupción con sesión simulada; manual con una llamada entrante y con Siri.
  - _Requisitos: R6_

- [ ] 6. Prueba en dispositivo de segundo plano (Multipeer y red UDP/Bonjour)
  - [ ] 6.1 Preparar la matriz de R7.1 en `TEST_PLAN.md` con la plantilla de resultados de R7.2.
  - [ ] 6.2 Ejecutar con al menos 2 iPhones físicos y 1 Android o Mac; 3 duraciones (1, 5, 30 min); registrar versión de iOS y modelo.
  - [ ] 6.3 Escribir los resultados en `KNOWN_LIMITATIONS.md` y fijar la tabla `backgroundPathPreference` (iOS) con los valores observados; las celdas sin prueba quedan en `desconocido`.
  - [ ] 6.4 Si Multipeer o UDP no sobreviven en segundo plano con `audio`, evaluar el modo `voip` con CallKit (autorizado por el usuario) en un build de depuración, con una prueba del arranque, y registrar el resultado de ambos modos. No se publica en TestFlight sin aprobación escrita y sin documentar el riesgo de revisión de Apple.
  - [ ] 6.5 Documentar la decisión final con la evidencia de 6.2 a 6.4 en `KNOWN_LIMITATIONS.md` y en el README.
  - CT: todas las celdas de R7.1 tienen resultado o están marcadas "no probada" con motivo; la tabla está en el código.
  - Pruebas: manual con dispositivos (única forma posible).
  - _Requisitos: R7, R6.6_

- [ ] 7. Medición de tráfico de control y campo
  - [ ] 7.1 Contador de bytes de control por nodo en el diagnóstico (iOS) y en el log (Android, Mac).
  - [ ] 7.2 Medir R5.1 con 5 vecinos o con simulación de 5 conexiones.
  - CT: R5.1 ≤ 4 kbps; si no se cumple, se ajusta la cadencia y se documenta.
  - _Requisitos: R5_

- [ ] 8. Interoperabilidad y publicación
  - [ ] 8.1 Repetir la matriz C1 del spec 1 con esta build.
  - CT: las cuatro combinaciones pasan; en especial un nodo baseline en el grupo sigue oyendo y siendo oído.
  - _Requisitos: R1.2, R2.3_
