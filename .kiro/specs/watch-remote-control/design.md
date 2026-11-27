# Diseño: watch-remote-control
## Visión general
Se añade una app de watchOS compañera que habla con el iPhone por WatchConnectivity y solo manda órdenes y muestra estado. Ya existe una versión parcial y desactivada (`MotoBridgeWatch/` con un botón de hablar por mantener, `WatchBridge.swift` en el iPhone, y el target comentado en `project.yml`). Este diseño la reemplaza por: (1) un archivo de protocolo compartido, `WatchProtocol.swift`, con comandos, estado y validación; (2) un lado iPhone en el que `WatchBridge` recibe comandos, los valida, llama a las funciones que ya existen en `NetworkBridgeController` (`setTransmitting`, `sendAlarm`, `start`, `stop`) y publica un estado completo cada vez que algo cambia; (3) un lado reloj de tres pantallas (control, estado, bridge) que muestra el último estado recibido, deshabilita todo y muestra "iPhone no alcanzable" cuando no hay enlace, y confirma cada acción con una pantalla y una háptica; (4) un target `MotoBridgeWatch` en `project.yml` incrustado en la app iOS con id `com.motobridge.app.monkeyfon.watchkitapp`. El iPhone es la fuente de verdad: el reloj nunca cambia su estado por un toque, solo por lo que el iPhone responde o publica. El audio no pasa por el reloj en ningún punto.
**Stack (bloqueado al aprobar):** Swift y SwiftUI en watchOS (app de reloj de un solo target con `WKApplication`, sin extensión WatchKit), `WatchConnectivity` (`WCSession`) en ambos lados, `WatchKit` (`WKInterfaceDevice`) para la háptica, Combine en el iPhone para observar el controlador, XCTest para pruebas. Generación con xcodegen (`project.yml`). Deployment watchOS 10.0 (iOS 17.0 sin cambios; ver decisión 5). Sin dependencias de terceros nuevas. Sin App Groups, sin entitlements, sin extensiones.
## Decisión 1: WatchConnectivity y qué mecanismo usa cada cosa
Se usan los tres canales de `WCSession` según para qué sirven, no uno solo.
- **Comandos reloj a iPhone: `sendMessage(_:replyHandler:errorHandler:)`.** Es el único canal interactivo con respuesta. Falla de inmediato si el iPhone no es alcanzable y no encola, que es lo que se quiere para una alarma: un comando de emergencia que llegara tarde sería peor que uno que falla a la vista. Se descartan `transferUserInfo` (cola que entrega tarde y en orden) y `updateApplicationContext` (solo el último valor, sin respuesta) para comandos.
- **Estado iPhone a reloj: `updateApplicationContext` siempre, más `sendMessage` si el reloj es alcanzable.** El contexto guarda el último estado y se entrega aunque el reloj esté dormido; es el estado de referencia. El `sendMessage` es la vía rápida para el reloj con la app abierta. El reloj aplica el que tenga el número de secuencia mayor, así que recibir ambos no duplica nada.
- **Petición de estado: `sendMessage` con `cmd: getState` y respuesta.** Se usa al abrir la app del reloj y al volver el enlace. La respuesta contiene el estado y lo aplica el reloj sin comparar secuencia (restablece el piso; ver "Invariantes").
Alternativa descartada para el estado: *solo `sendMessage`*. Pierde estado si el reloj está dormido o fuera de alcance al producirse el cambio. Alternativa descartada: *solo contexto*. Su entrega con el reloj dormido o la app en segundo plano no tiene garantía de tiempo y no cumple el objetivo de ≤ 2 s con la app abierta.
Las funciones de `WCSession` de iPhone solo se usan si `WCSession.isSupported()` (falso en iPad) y, para enviar, si `isPaired && isWatchAppInstalled`. Sin reloj emparejado el código no hace nada ni registra errores (NF2).
## Decisión 2: hablar mientras se mantiene, no entra en v1
**Elegido:** v1 solo abre y cierra el micrófono (control de dos estados). El gesto de mantener para hablar queda en backlog hasta tener medición.
Evidencia disponible y límites:
- `sendMessage` es el canal interactivo de Apple, pero la documentación no promete latencia ni entrega en un plazo. Va por Bluetooth (o Wi-Fi) entre reloj y iPhone y puede tardar desde decenas de milisegundos hasta segundos, o fallar si el enlace se interrumpe. No hay en el repositorio ninguna medición de este enlace y en este paso no hay dispositivos para medirla. Por eso no se afirma un número.
- Mantener para hablar exige dos mensajes correctos (pulsar y soltar). Si "soltar" se pierde o llega tarde, el micrófono queda abierto y transmite lo que ocurra en la moto o en el entorno al grupo entero. En el modo de abrir y cerrar, un mensaje perdido deja el micrófono en el estado anterior y el rider lo ve (confirmación por estado), que es un fallo seguro.
- Una latencia de pulsar que supere unos 300 ms hace perder el inicio de la frase, y una de soltar corta o alarga el final; ambas se notan en un intercom.
- El hablar-mientras-se-mantiene del código anterior no tiene confirmación, ni temporizador de seguridad, ni comprobación de `isRunning`.
Alternativas:
- *Mantener para hablar con protección (el iPhone cierra el micrófono si no recibe renovación del reloj cada 1 s, tope de 30 s)*: resuelve el micrófono atascado, pero añade tráfico continuo y estado en el iPhone, y no resuelve la latencia de pulsar.
- *Solo abrir y cerrar (elegido)*: simple, coherente con el interruptor "Microfono abierto" del iPhone y con fallos visibles.
**Criterio para reconsiderar (backlog):** medir en iPhone y reloj reales, con el bridge corriendo y el iPhone bloqueado y desbloqueado, 200 pulsaciones: tiempo desde el toque hasta que el iPhone ejecuta `setTransmitting`. Se reconsidera si p95 ≤ 300 ms, 0 mensajes de soltar perdidos y la protección de 1 s no se dispara en falso. Si se cumple, se diseña como cambio aparte con la protección descrita arriba. La tarea 7 de tasks.md registra la medición como evidencia, sin implementar el gesto.
## Decisión 3: protocolo de mensajes (`MotoBridge/Core/Watch/WatchProtocol.swift`)
Un archivo nuevo, solo con `Foundation`, compilado en los dos targets (el de iPhone ya incluye todo `MotoBridge/`; el del reloj lo lista por ruta de archivo, igual que `MonoBridgeRelay` hace con los archivos del core en `project.yml`). Contiene: las constantes de claves, `WatchCommand`, `WatchReply`, `WatchState`, el código de errores y `WatchStateStore` (lógica de secuencia). Los mensajes de `WCSession` son diccionarios de lista de propiedades (`[String: Any]`).
**Comando (reloj a iPhone):**
| Clave | Tipo | Obligatoria | Regla |
|---|---|---|---|
| `v` | Int | sí | Debe ser `1`. Otro valor: `unsupportedVersion`. |
| `cmd` | String | sí | Uno de `getState`, `setMic`, `alarm`, `startBridge`, `stopBridge`. Otro: `badRequest`. |
| `id` | String | sí, salvo `getState` | 1 a 64 caracteres (UUID del reloj). Vacío o más largo: `badRequest`. |
| `open` | Bool | solo en `setMic` | Falta o no es Bool: `badRequest`. |
Las claves desconocidas se ignoran (compatibilidad hacia delante).
**Respuesta (iPhone a reloj):** `v` (Int), `ok` (Bool), `err` (String, solo si `ok` es falso: `notRunning`, `needsPhone`, `badRequest`, `unsupportedVersion`, `internal`), `note` (String opcional: `alreadyActive`, `noChange`) y `state` (el estado completo, siempre presente, ya actualizado por la acción).
**Estado (`WatchState`):**
| Clave | Tipo | Significado |
|---|---|---|
| `v` | Int | `1` |
| `seq` | Int | Milisegundos desde 1970 en el iPhone, forzado a ser estrictamente creciente dentro del proceso (`max(anterior + 1, ahora)`). |
| `running` | Bool | `controller.isRunning` |
| `mic` | Bool | `controller.isTransmitting` |
| `alarm` | Bool | `controller.alarmActive` |
| `peerCount` | Int | `controller.connectedPeers.count` (número real) |
| `peers` | [String] | Hasta 8 nombres, cada uno saneado: sin caracteres de control, recortado a 24 caracteres, vacío reemplazado por "Rider". |
| `canStart` | Bool | Permiso de micrófono concedido y app en primer plano activa (decisión 6). |
Tamaño del contexto: menos de 1 KB. Los nombres de riders son datos de la red (no confiables); se sanean en el iPhone antes de enviarse y el reloj los muestra como texto, nunca como formato.
Alternativa descartada: *`Codable` a `Data` en una sola clave*. Los diccionarios de propiedades se pueden revisar en el log y tolerar claves nuevas sin cambiar el formato; el costo de escribir el mapeo es bajo.
## Decisión 4: lado iPhone
**Archivos:** `MotoBridge/Core/Watch/WatchBridge.swift` (reescrito), `MotoBridge/Core/Watch/WatchCommandHandler.swift` (nuevo), `MotoBridge/Core/Bridge/NetworkBridgeController.swift` (cambios mínimos), `MotoBridge/App/MotoBridgeApp.swift` (una línea).
- **`WatchBridge`** pasa a ser un singleton (`WatchBridge.shared`). Es el `WCSessionDelegate`. Se activa desde `MotoBridgeApp.init()`. Razón: hoy se crea dentro del controlador, que se construye de forma perezosa al crearse la vista; si el sistema lanza la app del iPhone en segundo plano para entregar un mensaje del reloj, el delegado debe existir antes. `activate()` es barato y no toca micrófono ni audio, así que no reintroduce el riesgo del arranque en frío que el controlador documenta (`start()`, comentario sobre el crash). Implementa `didReceiveMessage(_:replyHandler:)`; un mensaje sin `replyHandler` se ignora con warning.
- **`WatchCommandHandler`** es una clase pequeña y sin dependencia de UIKit que opera sobre un protocolo:
  ```swift
  protocol BridgeControlling: AnyObject {
      var isRunning: Bool { get }
      var isTransmitting: Bool { get }
      var alarmActive: Bool { get }
      var connectedPeerNames: [String] { get }
      var canStartRemotely: Bool { get }
      func setMic(_ open: Bool)
      func triggerAlarm()
      func startBridge()
      func stopBridge()
  }
  ```
  `NetworkBridgeController` lo implementa en una extensión en `WatchCommandHandler.swift`: `setMic` llama a `setTransmitting`, `triggerAlarm` a `sendAlarm`, `startBridge` a `start`, `stopBridge` a `stop` (nunca a `shutdownAndExit`), `connectedPeerNames` a `connectedPeers.map(\.name)`, y `canStartRemotely` a `AVAudioApplication.shared.recordPermission == .granted && UIApplication.shared.applicationState == .active`. Esa extensión se escribe como un `extension NetworkBridgeController` en el archivo del handler y no necesita acceso privado: todas las propiedades usadas son `internal` o `private(set)`.
  `handle(_ message: [String: Any], completion: @escaping ([String: Any]) -> Void)` se ejecuta siempre en el hilo principal: valida, ejecuta, y llama a `completion` desde un `DispatchQueue.main.async` posterior a la acción. Ese salto importa porque `setTransmitting` actualiza `isTransmitting` con su propio `DispatchQueue.main.async`; la cola principal es FIFO, así que el estado que se construye en el segundo salto ya incluye el cambio.
- **Reglas por comando** (en este orden, la primera que falle responde):
  | Comando | Regla | Resultado |
  |---|---|---|
  | todos | `v != 1` | `unsupportedVersion` |
  | todos menos `getState` | `id` ya visto (cola de los últimos 16) | Se devuelve la respuesta guardada para ese `id` y no se ejecuta nada |
  | `getState` | — | `ok` con estado |
  | `setMic(true)` | `!isRunning` | `notRunning` |
  | `setMic(open)` | `isTransmitting == open` | `ok`, `note: noChange` |
  | `setMic(open)` | — | `setMic(open)`, `ok` |
  | `alarm` | `!isRunning` | `notRunning` |
  | `alarm` | `alarmActive` | `ok`, `note: alreadyActive` (no llama a `sendAlarm`) |
  | `alarm` | — | `triggerAlarm()`, `ok` |
  | `startBridge` | `isRunning` | `ok`, `note: noChange` |
  | `startBridge` | `!canStartRemotely` | `needsPhone` |
  | `startBridge` | — | `startBridge()`, `ok` |
  | `stopBridge` | `!isRunning` | `ok`, `note: noChange` |
  | `stopBridge` | — | `stopBridge()`, `ok` |
- **Publicación de estado:** `WatchBridge.attach(_ controller)` (idempotente, la llama el `init` del controlador al final) se suscribe con `Publishers.CombineLatest4($isRunning, $isTransmitting, $alarmActive, $connectedPeers)` y `.throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)` (máximo 5 por segundo, NF1). Cada valor genera un `WatchState` nuevo y lo envía como decide la decisión 1. Además se publica al activarse la sesión y al cambiar la alcanzabilidad.
- **Cambios en `NetworkBridgeController.swift`:** quitar `private let watch = WatchBridge()` (línea 24); reemplazar el bloque `watch.onPTTChange` (líneas 519 a 522) por `WatchBridge.shared.attach(self)` al final del `init`; quitar la llamada `watch.sendStateToWatch(...)` (línea 1093). No se cambia `setTransmitting`, `sendAlarm`, `start` ni `stop`. Las comprobaciones de `isRunning` viven en el handler (ver "Invariantes").
- Cuando llega el primer comando y el controlador aún no existe (app lanzada en segundo plano por el sistema), el handler obtiene `NetworkBridgeController.shared` en el hilo principal, lo que lo crea y llama a `attach`. Los App Intents de Siri ya hacen lo mismo (`MotoBridgeIntents.swift`).
## Decisión 5: target de watchOS en `project.yml` y versiones mínimas
**Elegido:** un solo target `MotoBridgeWatch` de tipo `application`, plataforma `watchOS`, sin extensión (modelo de app de reloj de un solo target, vigente desde watchOS 7 y el que genera Xcode hoy). Se activa la dependencia `- target: MotoBridgeWatch` con `embed: true` en `MotoBridge`, que hace que xcodegen lo incruste en la carpeta Watch del .app. Configuración:
```yaml
  MotoBridgeWatch:
    type: application
    platform: watchOS
    deploymentTarget: "10.0"
    sources:
      - path: MotoBridgeWatch
      - path: MotoBridge/Core/Watch/WatchProtocol.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.motobridge.app.monkeyfon.watchkitapp
        PRODUCT_NAME: MotoBridgeWatch
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: "Mono Bridge"
        INFOPLIST_KEY_WKApplication: YES
        INFOPLIST_KEY_WKCompanionAppBundleIdentifier: com.motobridge.app.monkeyfon
        INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp: NO
        TARGETED_DEVICE_FAMILY: "4"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_PREVIEWS: YES
```
`TARGETED_DEVICE_FAMILY: "4"` es obligatorio: el valor global `"1,2"` de `project.yml` es de iPhone y iPad. `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `DEVELOPMENT_TEAM` y `CODE_SIGN_STYLE: Automatic` se heredan de la configuración global, lo que cumple R6.3 y R6.4 sin duplicar. La clave `INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp` y el efecto exacto del bloque se verifican en la tarea 1 con una compilación real (si Xcode 27 no acepta la clave en el Info.plist generado, se declara en un `Info.plist` propio del reloj; no cambia el diseño).
**Nombre mostrado: "Mono Bridge".** Es el mismo nombre del iPhone (`CFBundleDisplayName` en `Info.plist`), tiene 11 caracteres y no se trunca en la cuadrícula del reloj en tamaños de 41 mm en adelante (a confirmar en la tarea 6). Alternativa descartada: "MB Control", que obliga al rider a reconocer dos nombres.
**Firma:** el App ID `com.motobridge.app.monkeyfon.watchkitapp` no existe aún en la cuenta. Con firma automática y `-allowProvisioningUpdates`, Xcode lo registra y crea el perfil. Eso exige acceso a la cuenta 48V68SFH7Q y es la causa probable del bloqueo anterior, atribuido a una cuenta personal (comentario en `project.yml`). No se tocan certificados ni perfiles del iPhone. La tarea 1 comprueba esto antes de escribir código.
**Versiones mínimas.** `project.yml` dice iOS 17.0 y watchOS 10.0 (`options.deploymentTarget`). El README de `.kiro/specs/` dice que el mínimo de iOS subirá a 26 (spec 5, aún sin aplicar). watchOS 10 empareja con iOS 17 y posteriores, así que no se sube nada ahora y no se excluye a nadie del iPhone. Cuando el spec 5 suba iOS a 26, el mínimo del reloj sube a `26.0` en el mismo cambio de `project.yml` (un watchOS 26 solo empareja con iOS 26); se anota en las tareas del spec 5 como coordinación. Si Xcode 27 no permite compilar para watchOS 10.0, la tarea 1 lo detecta y se sube a 11.0 documentándolo.
**Icono:** `MotoBridgeWatch/Assets.xcassets/AppIcon.appiconset/Contents.json` usa hoy entradas de plataforma `ios` y no contiene ninguna imagen. Se reemplaza por una entrada `{ "idiom": "universal", "platform": "watchos", "size": "1024x1024", "filename": "AppIcon-1024.png" }` con el mismo `AppIcon-1024.png` del iPhone (copiado, no vinculado). Sin él, el archivo (`archive`) falla en la validación.
## Decisión 6: iniciar y detener el bridge, "si es seguro"
**Elegido:** detener siempre se acepta, con confirmación en el reloj. Iniciar se acepta solo si `canStartRemotely`.
- *Por qué iniciar se limita:* `start()` pide el permiso de micrófono si no está decidido (el diálogo solo se puede contestar en el iPhone) y arranca el motor de audio y la sesión. Arrancar captura de micrófono sin que la app esté en primer plano activo puede fallar en iOS, y el controlador evita tocar el micrófono en frío por un crash previo documentado. No hay evidencia en el repo de que arrancar desde segundo plano funcione. Por eso, si no se cumple "permiso concedido y app activa", el iPhone responde `needsPhone` y el reloj dice "Abre Mono Bridge en el iPhone". Es un fallo visible, no uno silencioso.
- *Por qué detener pide confirmación:* un toque accidental con guantes corta el audio de todo el grupo. La pantalla de confirmación es la misma de la alarma (5 s de caducidad).
- *Qué se mide en la tarea 6:* si `start()` desde el reloj funciona con la app en segundo plano y la pantalla bloqueada. El resultado se anota; v1 no cambia la regla de seguridad con él.
Alternativa descartada: *no incluir iniciar/detener*. El usuario lo pidió; la limitación lo hace seguro sin quitarlo. Alternativa descartada: *iniciar desde segundo plano sin comprobar*. Puede dejar el bridge a medias (corriendo sin audio) sin que el rider lo sepa.
## Decisión 7: complication y widget fuera de v1
**Elegido:** no se incluyen. Una complication necesita una extensión de widget (WidgetKit) con su propio bundle id, App ID, perfil y, para leer el estado, un App Group o un canal de datos nuevo en el reloj. Eso multiplica la superficie de firma automática que la restricción pide no romper, y no es "barato y seguro". Queda en backlog: cuando el reloj funcione y firme, un widget de Smart Stack que lea el último estado del contexto (sin App Group, con un `UserDefaults` compartido o un archivo en el contenedor del reloj) es un spec aparte.
## Decisión 8: la app del reloj
**Archivos nuevos y cambios en `MotoBridgeWatch/`:**
- `MotoBridgeWatchApp.swift`: crea un solo `WatchRemoteModel` como `@StateObject` y lo pasa como `environmentObject`. Pide estado cuando `scenePhase` pasa a `.active`.
- `WatchRemoteModel.swift` (reemplaza a `WatchConnectivityClient.swift`): `@MainActor ObservableObject` y `WCSessionDelegate`. Publica `state: WatchState?`, `reachable: Bool`, `controlOp: Op`, `alarmOp: Op` y `refreshing: Bool`, con `enum Op { case idle, pending, done(String?), failed(String) }`. Métodos: `refresh()`, `setMic(_:)`, `sendAlarm()`, `startBridge()`, `stopBridge()`. Los resultados de los métodos de `WCSession` llegan en hilos de fondo y se pasan a `MainActor`.
- `ContentView.swift` (reemplaza a `WatchPTTView.swift`): `TabView` de tres páginas verticales más el aviso de enlace.
- `ConfirmView.swift`: pantalla de confirmación con cuenta atrás de 5 s.
- `Haptics.swift`: envoltorio mínimo de `WKInterfaceDevice.current().play(_:)` con `.success`, `.failure` y `.click`.
**Pantallas:**
1. *Control:* botón grande de micrófono ("MICRÓFONO ABIERTO" verde o "MICRÓFONO CERRADO" gris, siempre con texto e icono, no solo color) y botón rojo "ALARMA". Cada uno mide al menos 44 pt de alto.
2. *Estado:* "Bridge activo" o "Bridge detenido", "N riders conectados" y la lista de nombres (con "+N más"). Si `alarm` es verdadero, una franja roja "ALARMA ACTIVA".
3. *Bridge:* botón "Iniciar bridge" o "Detener bridge" (según `running`), que en el segundo caso abre la confirmación.
**Aviso de enlace:** una franja superior fija, visible en las tres páginas, con "iPhone no alcanzable" cuando `!reachable` o la sesión no está activada. En ese estado los botones están deshabilitados y los valores de estado muestran "—". La alcanzabilidad viene de `WCSession.isReachable` (`sessionReachabilityDidChange`), no de timers.
**Flujo de la alarma:** botón ALARMA, a `ConfirmView` ("¿Enviar alarma a todo el grupo?", botones "ENVIAR ALARMA" y "Cancelar", 5 s). Tras confirmar, `sendAlarm()` genera un `id` UUID, pone `alarmOp = .pending` y envía el comando con `sendMessage` y un temporizador de 5 s. La primera de tres cosas que ocurra define el resultado:
- Respuesta con `ok`: `.done`, pantalla roja "Alarma enviada" durante 3 s y `Haptics.success`.
- Respuesta con error o `errorHandler` (por ejemplo `WCErrorCodeNotReachable`): `.failed(motivo)`, pantalla "NO SE ENVIÓ" con el motivo y `Haptics.failure`.
- Vence el temporizador: `.failed("Sin confirmación. Revisa el iPhone")` y `Haptics.failure`. Si la respuesta llega después, se ignora para la pantalla pero se aplica su `state`.
La alarma y el control tienen cada uno su ranura de operación pendiente (`alarmOp` y `controlOp`); una operación de micrófono pendiente nunca bloquea la alarma. Mientras `controlOp` esté en `.pending`, los botones de micrófono y de bridge están deshabilitados para no acumular comandos.
**Resultado de micrófono:** el toque envía `setMic(open: !state.mic)` con un `id` nuevo y pone `.pending`; el botón muestra "…". La respuesta trae el estado real: se aplica, se da `Haptics.success` (o `failure` si `ok` es falso), y el botón refleja el estado del iPhone.
**Motivos mostrados:** `notRunning` es "Bridge detenido"; `needsPhone` es "Abre Mono Bridge en el iPhone"; `badRequest` y `unsupportedVersion` son "Actualiza la app del reloj o del iPhone"; `internal` es "Error en el iPhone".
## Decisión 9: documentación
`KNOWN_LIMITATIONS.md` L11 se reescribe: el reloj es control remoto (micrófono abierto/cerrado, alarma, estado, iniciar/detener), ya no "hablar mientras se mantiene". `README.md` añade el reloj a la lista de plataformas y una nota de que `xcodegen generate` incluye el target. `CHANGELOG.md` recibe una entrada. `ARCHITECTURE.md` recibe un párrafo si menciona el módulo del reloj.
## Archivos a modificar
- Nuevos: `MotoBridge/Core/Watch/WatchProtocol.swift`, `MotoBridge/Core/Watch/WatchCommandHandler.swift`, `MotoBridgeWatch/WatchRemoteModel.swift`, `MotoBridgeWatch/ContentView.swift`, `MotoBridgeWatch/ConfirmView.swift`, `MotoBridgeWatch/Haptics.swift`, `MotoBridgeWatch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`, `MotoBridgeTests/WatchProtocolTests.swift`, `MotoBridgeTests/WatchCommandHandlerTests.swift`.
- Reescritos: `MotoBridge/Core/Watch/WatchBridge.swift`, `MotoBridgeWatch/MotoBridgeWatchApp.swift`, `MotoBridgeWatch/Assets.xcassets/AppIcon.appiconset/Contents.json`.
- Eliminados: `MotoBridgeWatch/WatchConnectivityClient.swift`, `MotoBridgeWatch/WatchPTTView.swift`.
- Modificados: `project.yml` (target y dependencia), `MotoBridge/Core/Bridge/NetworkBridgeController.swift` (tres cambios pequeños de la decisión 4), `MotoBridge/App/MotoBridgeApp.swift` (activar `WatchBridge.shared`), `MotoBridge.xcodeproj/` (regenerado con xcodegen y revisado: el diff solo debe agregar el target del reloj, la fase de incrustación y los archivos nuevos), `KNOWN_LIMITATIONS.md`, `README.md`, `CHANGELOG.md`.
- No se tocan: `Info.plist` del iPhone, `android/`, `MonoBridgeRelay/`, la configuración de git.
## Manejo de errores
| Operación | Condición de fallo | Recuperable | Qué recibe quien llama | Registro |
|---|---|---|---|---|
| Activar `WCSession` (iPhone) | `isSupported()` falso (iPad) | Sí (sin función) | Nada; sin reloj no hay UI | info, una vez |
| Activar `WCSession` (iPhone) | `activationDidCompleteWith` con `error` | Sí: se reintenta al siguiente `activate` (reactivación en `sessionDidDeactivate`) | Estado no se publica | error con el texto del error |
| Recibir comando en iPhone | Sin `replyHandler` | Sí | Nada | warning |
| Recibir comando en iPhone | `v` ausente o distinto de 1 | Sí | `ok:false`, `err:unsupportedVersion` | warning |
| Recibir comando en iPhone | `cmd` desconocido; `id` o `open` inválidos | Sí | `ok:false`, `err:badRequest` | warning con el nombre del comando y el motivo, sin el contenido completo |
| Comando en iPhone | Bridge detenido (mic abrir, alarma) | Sí | `ok:false`, `err:notRunning` | info |
| Comando de inicio | `!canStartRemotely` | Sí (el rider abre la app) | `ok:false`, `err:needsPhone` | info |
| Comando duplicado (`id` repetido) | — | n/a | Respuesta guardada | debug |
| Excepción inesperada al construir la respuesta | — | Sí | `ok:false`, `err:internal` | error |
| `updateApplicationContext` | Lanza error (sesión no activada, reloj no instalado) | Sí: el siguiente cambio vuelve a intentar | Nada (el reloj usa su último estado o el `sendMessage`) | warning, como máximo una vez por minuto |
| `sendMessage` de estado (iPhone) | `errorHandler` | Sí | Nada | debug |
| `sendMessage` de comando (reloj) | `errorHandler` (no alcanzable, entrega fallida) | Sí: el rider reintenta | Operación `.failed(motivo)`, háptica de fallo | Sin registro (el reloj no tiene bitácora; el estado se ve en pantalla) |
| `sendMessage` de comando (reloj) | Sin respuesta en 5 s | Sí | `.failed("Sin confirmación…")`, háptica de fallo | Ninguno |
| `getState` (reloj) | Falla o sin respuesta | Sí | `refreshing` termina; el estado queda en "—" si no había ninguno; reintenta al siguiente cambio de alcanzabilidad o al activar la app | Ninguno |
Ninguna falla es fatal: el peor caso es que el reloj muestre un error y el rider use el iPhone. Ningún error del reloj detiene el bridge del iPhone ni su audio.
## Validación de entradas
| Entrada | Obligatoria | Tipo y límites | Si falla |
|---|---|---|---|
| `v` (comando) | Sí | Int, igual a 1 | `unsupportedVersion` |
| `cmd` | Sí | String, valor del conjunto permitido | `badRequest` |
| `id` | Sí, salvo `getState` | String de 1 a 64 caracteres | `badRequest` |
| `open` | Solo `setMic` | Bool | `badRequest` |
| Claves extra | No | Cualquier tipo | Se ignoran |
| Nombres de riders (salida, no entrada) | n/a | Saneados en el iPhone: sin caracteres de control, ≤ 24 caracteres, ≤ 8 nombres | Se recortan, no fallan |
| Estado en el reloj (`seq`, `peers`, etc.) | Sí | `v == 1`, `seq` Int, `peers` de String con ≤ 8 elementos | Estado descartado, se conserva el anterior |
La validación vive en `WatchProtocol.swift` (funciones puras `WatchCommand.parse` y `WatchState.parse`), una sola implementación para los dos lados.
## Invariantes
- **El iPhone es la fuente de verdad del estado.** Lo aplica la capa de la app del reloj (`WatchRemoteModel`): el único código que escribe `state` es `apply(_:)`, que se llama con lo publicado por el iPhone o con la respuesta a un comando. Ningún botón escribe `state`. Se aplica ahí porque es el único punto por el que pasa el estado en el reloj.
- **Un estado viejo no sobrescribe a uno nuevo.** `WatchStateStore.apply` descarta `seq <= último`. Excepción: la respuesta a `getState` restablece el piso, para recuperarse si el reloj del iPhone retrocedió o la app del iPhone se reinició con un `seq` menor. Se aplica en `WatchStateStore` (lógica pura, probada).
- **La alarma y la apertura de micrófono nunca corren con el bridge detenido.** Las comprobaciones `isRunning` se hacen en `WatchCommandHandler` y no dentro de `setTransmitting`: cambiar `setTransmitting` afectaría a Siri, a la alarma y al modo caminar, que hoy dependen de su comportamiento. El handler es el único punto de entrada remoto, así que basta.
- **Una alarma no se encola ni se reintenta sola.** La aplica el reloj (solo `sendMessage`, sin reintento automático) y el iPhone (idempotencia por `id` y por `alarmActive`).
- **Nada de datos obsoletos mostrados como actuales.** Lo aplica la vista del reloj: con `!reachable` los valores se reemplazan por "—" y los controles se deshabilitan.
- **Comportamiento existente intacto.** `setTransmitting`, `sendAlarm`, `start`, `stop` no cambian. Un cambio a esas funciones no está en este spec.
## Casos límite
- **El reloj envía el micrófono abierto mientras corre una alarma:** el iPhone lo acepta; la alarma cierra el micrófono a los 6 s, también el que el rider había abierto (comportamiento actual de `sendAlarm`, no se cambia; anotado como limitación en `KNOWN_LIMITATIONS.md`).
- **Dos toques de micrófono seguidos:** el segundo se bloquea en el reloj mientras `controlOp` sea `.pending`; si llega al iPhone, el comando absoluto es idempotente.
- **El rider cambia el micrófono en el iPhone mientras hay un comando en vuelo:** la respuesta trae el estado real; el reloj muestra eso, no lo pedido.
- **El iPhone se bloquea:** el bridge sigue por el modo de fondo `audio`. Que el reloj siga alcanzable con el iPhone bloqueado es una suposición de la documentación de Apple que se verifica en la tarea 6.
- **App del iPhone cerrada por el usuario (deslizada):** `isReachable` en el reloj puede ser falso hasta que el iPhone la abra; el reloj muestra "iPhone no alcanzable". No se intenta despertarla.
- **Reloj con la app en segundo plano:** el reloj solo mantiene el último contexto; al abrirla pide estado y muestra "Actualizando…".
- **Reloj sin iPhone cerca:** igual que sin alcance. `sendMessage` falla de inmediato.
- **Más de 8 riders:** se muestran 8 y "+N más"; el contador es el real.
- **Nombre vacío o con solo caracteres de control:** se muestra "Rider".
- **Reloj emparejado pero sin la app instalada:** `isWatchAppInstalled` falso; el iPhone no publica nada.
- **Cambio de reloj emparejado:** `sessionDidDeactivate` reactiva la sesión (ya existe en el código actual) y `sessionDidBecomeInactive` no hace nada.
- **iPad:** `WCSession.isSupported()` es falso; `attach` no suscribe nada.
## Testabilidad
- **Pruebas unitarias (en `MotoBridgeTests`, sin dispositivos), con `@testable import MotoBridge`:**
  - `WatchProtocolTests`: análisis de comandos (versión, `cmd` desconocido, `id` vacío o de 65 caracteres, `open` ausente o de tipo erróneo, claves extra), ida y vuelta de `WatchState`, saneado de nombres (control, longitud, vacío, más de 8), `WatchStateStore` (secuencia menor descartada, `getState` restablece el piso).
  - `WatchCommandHandlerTests` con un `FakeBridge: BridgeControlling`: cada fila de la tabla de reglas de la decisión 4, `id` duplicado (no ejecuta dos veces), alarma con `alarmActive`, inicio con `canStartRemotely` falso, y que la respuesta contiene el estado posterior a la acción.
- **Pruebas de integración / manuales con dispositivos (requeridas, no automatizables):** emparejamiento real iPhone y reloj; latencia de estado (R3.2); alarma extremo a extremo con otro rider; háptica (no se puede probar en simulador); aviso "iPhone no alcanzable" apagando el Bluetooth del reloj; reloj con iPhone bloqueado; app del iPhone cerrada; inicio desde segundo plano. El simulador de watchOS empareja con un simulador de iPhone y sirve para la UI y la lógica de mensajes, no para la háptica ni la latencia real.
- **Compilación:** esquemas `MotoBridge` (con tests), `MonoBridgeRelay` y Android antes y después; `xcodebuild archive` del iPhone para ver la incrustación y la firma.
## Respuestas a los puntos abiertos
- *Nombre en el reloj:* "Mono Bridge" (decisión 5).
- *Hablar mientras se mantiene:* no en v1; razones y criterio de reconsideración en la decisión 2. No se midió porque en este paso no hay dispositivos; la tarea 7 define y registra la medición.
- *Complication:* fuera de v1 (decisión 7).
- *Versión mínima:* watchOS 10.0 ahora; 26.0 cuando el spec 5 suba iOS a 26 (decisión 5).
