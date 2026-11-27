# Requisitos: watch-remote-control
## Objetivo
Añadir una app de Apple Watch que sea solo un **control remoto** de la app del iPhone: abrir y cerrar el micrófono, disparar la alarma de emergencia, ver el estado del bridge y de los riders conectados, y iniciar o detener el bridge cuando sea seguro. El reloj no capta ni reproduce audio; el audio sigue por el iPhone y sus audífonos. Aplica solo a iOS y a un target nuevo de watchOS. No toca Android ni Mac Relay.
## Dependencias
Ninguna técnica. No depende de los specs 1 a 7 y no los bloquea. Coordinación con el spec 5 (`apple-transport-network-framework`): cuando ese spec suba el mínimo de iOS a 26, el mínimo del reloj sube a watchOS 26 en el mismo cambio (ver design, decisión 5). Mientras tanto el reloj usa watchOS 10.0 para no cambiar lo que el iPhone ya soporta (iOS 17.0 vigente en `project.yml`).
## Origen y supuestos
- Decisión del usuario (mensajes 11 y 12): el reloj se usa "de control solamente". No hay audio en el reloj.
- Hecho explicado al usuario: el reloj no puede ser audífono Bluetooth del iPhone para este caso, y el audio en vivo por WatchConnectivity tiene latencia y estabilidad dudosas.
- Hecho del código: ya existe una versión parcial y desactivada. `MotoBridgeWatch/` (3 archivos Swift, solo botón "HABLAR" con mensaje `ptt`), `MotoBridge/Core/Watch/WatchBridge.swift` (lado iPhone) y su uso en `NetworkBridgeController.swift` (líneas 24, 520 y 1093). El target está comentado en `project.yml` por un problema de firma con una cuenta personal; hoy la cuenta es de pago (Team 48V68SFH7Q). El texto de `KNOWN_LIMITATIONS.md` L11 describe esa versión parcial y se actualiza.
- Hecho del código: los ids comentados en `project.yml` (`com.motobridge.app.watchkitapp`, compañero `com.motobridge.app`) no coinciden con el id real del iPhone (`com.motobridge.app.monkeyfon`). Se corrigen.
- Hecho del código: `setTransmitting(_:)` no comprueba si el bridge está corriendo; `sendAlarm()` sí (`guard isRunning`) y no informa del resultado.
- Supuesto A1: "riders conectados" son los vecinos directos en `connectedPeers` (hasta 5 por nodo). Los riders alcanzables solo por malla no se cuentan en v1.
- Supuesto A2: el idioma del reloj es español, como la app. No hay catálogo de localización.
- Supuesto A3: el reloj es compañero y depende del iPhone (no corre de forma independiente). Sin iPhone no hace nada útil.
- Supuesto A4: un solo iPhone y un solo reloj emparejados. WatchConnectivity solo comunica con el reloj emparejado activo.
- Decisión sobre puntos abiertos (detalle y razones en design.md): nombre en el reloj "Mono Bridge"; **hablar mientras se mantiene no entra en v1** (solo abrir y cerrar), con un protocolo de medición para reconsiderarlo; complication fuera de v1.
## Requisitos funcionales (EARS)
### R1. Micrófono del iPhone
CUANDO el rider toque el control de micrófono del reloj, EL SISTEMA DEBERÁ pedir al iPhone abrir o cerrar el micrófono, con el mismo efecto que el interruptor "Microfono abierto" (`setTransmitting`).
Criterios de aceptación:
1. R1.1 El comando es absoluto (`open: true` o `false`), no un conmutador, de modo que repetirlo no cambia el resultado.
2. R1.2 El control del reloj refleja el valor real del iPhone, no el último toque. Tras el toque muestra "pendiente" hasta recibir la respuesta o el estado del iPhone.
3. R1.3 Si el iPhone abre o cierra el micrófono por otra vía (interruptor en pantalla, Siri, alarma), el reloj lo refleja en ≤ 2 s con enlace.
4. R1.4 Abrir el micrófono con el bridge detenido se rechaza con el código `notRunning`; el reloj muestra el motivo y no cambia el estado.
5. R1.5 Cerrar el micrófono con el bridge detenido se acepta sin error.
6. R1.6 Éxito (confirmado por el iPhone) da una háptica de éxito; rechazo o falta de confirmación da una háptica de fallo.
### R2. Alarma de emergencia
CUANDO el rider confirme la alarma en el reloj, EL SISTEMA DEBERÁ pedir al iPhone ejecutar la misma alarma que `NetworkBridgeController.sendAlarm()` y decir al rider si se ejecutó.
Criterios de aceptación:
1. R2.1 Un solo toque en el botón de alarma no la envía: abre una pantalla de confirmación a pantalla completa con "ENVIAR ALARMA" y "Cancelar".
2. R2.2 La confirmación se cancela sola a los 5 s sin enviar nada.
3. R2.3 Tras confirmar, el reloj muestra "Enviando…" y espera la respuesta del iPhone un máximo de 5 s.
4. R2.4 Con respuesta `ok`, el reloj muestra "Alarma enviada" (pantalla roja a pantalla completa) y da una háptica de éxito. Con error o sin respuesta, muestra "NO SE ENVIÓ" con el motivo y da una háptica de fallo; el mensaje de falta de respuesta dice que no se pudo confirmar y que se revise el iPhone.
5. R2.5 La alarma se envía solo con `sendMessage` con el iPhone alcanzable. Nunca se encola (ni `transferUserInfo` ni contexto), para que una alarma no llegue minutos tarde.
6. R2.6 El reloj no reintenta solo. El rider reintenta a mano desde la pantalla de fallo.
7. R2.7 Con el bridge detenido, el botón de alarma del reloj está deshabilitado (igual que `alarmCard` en el iPhone con `.disabled(!controller.isRunning)`) y muestra el motivo.
8. R2.8 Una alarma ya activa (`alarmActive`) no se vuelve a disparar: el iPhone responde `ok` con `alreadyActive` y no llama a `sendAlarm()` otra vez.
9. R2.9 Un mismo comando (mismo `id`) recibido dos veces solo dispara una alarma.
### R3. Estado
EL SISTEMA DEBERÁ mostrar en el reloj el estado del bridge del iPhone: bridge activo o detenido, micrófono abierto o cerrado, alarma activa, número de riders conectados y sus nombres.
Criterios de aceptación:
1. R3.1 El iPhone es la fuente de verdad. El reloj no deduce ni conserva estado propio salvo el último recibido.
2. R3.2 Con enlace, un cambio en el iPhone (bridge, micrófono, alarma, lista de riders) llega al reloj en ≤ 2 s (p95, medido en dispositivo).
3. R3.3 La lista muestra hasta 8 nombres de 24 caracteres como máximo; con más, muestra "+N más". El número total es siempre el real.
4. R3.4 Un estado con número de secuencia menor o igual al ya aplicado se descarta.
5. R3.5 Al abrir la app del reloj, este pide el estado actual al iPhone y muestra "Actualizando…" hasta recibirlo.
6. R3.6 Con el bridge detenido el reloj muestra "Bridge detenido" y 0 riders.
### R4. Enlace con el iPhone
CUANDO el iPhone no sea alcanzable, EL SISTEMA DEBERÁ mostrar de forma clara "iPhone no alcanzable".
Criterios de aceptación:
1. R4.1 Con `WCSession.isReachable == false` o sesión no activada, aparece un aviso fijo y visible en todas las pantallas del reloj.
2. R4.2 Con el aviso, los controles de micrófono, alarma e inicio/parada están deshabilitados y los valores de estado se muestran como "—" (no se muestran datos viejos como si fueran actuales).
3. R4.3 Al volver el enlace, el aviso desaparece y el reloj pide el estado en ≤ 1 s.
4. R4.4 Ninguna acción falla en silencio: todo comando enviado termina en éxito o en un error visible.
### R5. Iniciar y detener el bridge
CUANDO el rider pida iniciar o detener el bridge desde el reloj, EL SISTEMA DEBERÁ ejecutarlo solo si es seguro.
Criterios de aceptación:
1. R5.1 Detener pide confirmación en el reloj (misma pantalla de confirmación que la alarma, con cancelación a los 5 s) porque corta el enlace con todo el grupo.
2. R5.2 Iniciar se acepta solo si el iPhone informa `canStart`: permiso de micrófono concedido y app en primer plano activa. En otro caso responde `needsPhone` y el reloj dice "Abre Mono Bridge en el iPhone".
3. R5.3 Iniciar con el bridge ya corriendo y detener con el bridge ya detenido responden `ok` sin acción (idempotentes).
4. R5.4 Detener usa `stop()`, nunca `shutdownAndExit()` (no cierra la app del iPhone).
5. R5.5 El resultado se confirma con háptica de éxito o fallo, como en R1.6.
### R6. Compilación, firma y empaquetado
EL SISTEMA DEBERÁ incluir el reloj como target de watchOS incrustado en la app iOS sin romper lo existente.
Criterios de aceptación:
1. R6.1 `xcodegen generate` genera el proyecto con el target del reloj y sin errores.
2. R6.2 El bundle id del reloj es `com.motobridge.app.monkeyfon.watchkitapp`; el id del iPhone no cambia.
3. R6.3 La firma sigue automática con el Team 48V68SFH7Q. No se agregan certificados, perfiles manuales ni entitlements.
4. R6.4 El target del reloj queda incrustado en la app iOS (carpeta Watch del .app) y comparte `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` con ella.
5. R6.5 Los builds existentes siguen compilando: esquema `MotoBridge` (iOS, incluye tests), esquema `MonoBridgeRelay` (macOS) y Android (`./gradlew assembleDebug`).
6. R6.6 El Info.plist, los modos de fondo, los permisos y el deployment target (17.0) del iPhone no cambian.
7. R6.7 La app del reloj muestra el nombre "Mono Bridge".
### R7. Protocolo iPhone y reloj
EL SISTEMA DEBERÁ usar un protocolo de mensajes versionado y validado entre iPhone y reloj.
Criterios de aceptación:
1. R7.1 Todo mensaje lleva la versión `v` (entero). Un mensaje con versión no soportada se responde con `unsupportedVersion` y no ejecuta nada.
2. R7.2 El iPhone valida cada comando recibido (tipo, campos y límites, ver design). Un comando inválido recibe `badRequest`, se registra con nivel warning y no cambia el bridge.
3. R7.3 El mensaje antiguo `ptt` deja de existir en iPhone y reloj. Nunca se publicó una build con reloj, así que no hay compatibilidad que conservar.
4. R7.4 El código del protocolo (claves, comandos, estado, validación) vive en un solo archivo compartido por ambos targets.
## Requisitos no funcionales
- NF1. Batería: el iPhone publica estado a lo sumo 5 veces por segundo (agrupación de cambios) y solo si hay un reloj emparejado con la app instalada.
- NF2. El iPhone sin reloj emparejado, y el iPad (donde `WCSession` no es compatible), no cambian de comportamiento ni registran errores.
- NF3. Ninguna acción del reloj bloquea el hilo principal del iPhone más allá de una llamada a las funciones existentes.
- NF4. Accesibilidad: cada control del reloj tiene etiqueta de VoiceOver; los botones de micrófono y alarma miden al menos 44 × 44 pt; el estado nunca se comunica solo por color.
- NF5. Privacidad: el reloj no pide ningún permiso (ni micrófono, ni ubicación, ni salud) y no envía datos a ninguna red.
## Criterios de aceptación globales (resumen verificable)
1. G1. Con iPhone y reloj reales emparejados, el bridge corriendo y un rider conectado: abrir y cerrar el micrófono desde el reloj cambia el interruptor "Microfono abierto" del iPhone y el otro rider oye la voz (R1).
2. G2. La alarma desde el reloj suena en el dispositivo del otro rider igual que la del iPhone (R2).
3. G3. Con el iPhone fuera de alcance (Bluetooth apagado en el reloj), todas las pantallas muestran "iPhone no alcanzable" y nada se puede enviar (R4).
4. G4. Los tres builds existentes compilan antes y después del cambio (R6.5).
5. G5. `xcodebuild archive` del esquema `MotoBridge` produce un .app con el reloj incrustado y firma válida (R6.3, R6.4). No se sube a TestFlight.
## Fuera de alcance
- Audio en el reloj: captura, reproducción, "hablar" con audio del reloj.
- Hablar mientras se mantiene (push-to-talk por mantener). Queda en backlog con protocolo de medición (design, decisión 2).
- Complication, widget o Smart Stack (design, decisión 7).
- GPS, sensores o salud del reloj; modo rescate en el reloj.
- Cambios en Android, Mac Relay, protocolo de red entre riders o `Info.plist` del iPhone.
- Subir builds a TestFlight o App Store Connect; textos de la ficha de la tienda.
- Reloj independiente del iPhone; controlar volumen, canal privado o subgrupos.
- Notificaciones al reloj cuando un rider se conecta o desconecta.
- Cambios de `git config`.
