# Diseño: apple-transport-network-framework

## Visión general

El controlador de iOS (`NetworkBridgeController.swift`, 1840 líneas) hoy trata a Multipeer como transporte principal y a UDP como "gateway", con un puente que reenvía lo que llega por uno hacia el otro. Un mismo iPhone conectado por los dos caminos aparece como dos vecinos y, con la malla apagada, nada evita que su voz suene dos veces. Este spec reemplaza ese puente por un transporte compuesto, `MultiPathTransport`, que implementa `AudioTransport` y contiene dos caminos hijos: el de Multipeer (código existente, aislado) y uno nuevo de Network framework reconstruido con la API de iOS 26. El compuesto asocia las conexiones a un vecino por su `ID`, elige camino de envío por calidad, envía por ambos caminos cuando el primario es débil, y pasa todo lo recibido por una única deduplicación antes de que llegue al jitter buffer o al relay. El mínimo de iOS sube a 26 y el de macOS a 26.

**Stack (bloqueado al aprobar):** Swift (SwiftUI) con Network framework de iOS/macOS 26 (`NetworkListener`, `NetworkBrowser`, `NetworkConnection`, protocolo `UDP`), Multipeer Connectivity existente, Bonjour `_motobridge._udp`; Kotlin con `NsdManager` y sockets UDP en Android (sin cambios de librerías). Deployment iOS 26.0, macOS 26.0, Android minSdk 26. Sin dependencias de terceros nuevas; la librería `swift-opus` ya está en `project.yml`.

## Decisión 1: caminos paralelos tras un transporte compuesto

**Elegido:** `MultiPathTransport` implementa `AudioTransport` (`AudioTransport.swift:55-71`) y expone al controlador una sola lista de vecinos, un solo `sendAudio` y un solo `onAudioData`. El controlador deja de tener `gatewayTransport` y `wireGatewayTransport`.

Alternativas descartadas:
- *Mantener el puente y añadir deduplicación en el puente*: el controlador seguiría viendo dos listas de vecinos, el radar tendría dos entradas por iPhone y el relay del spec 4 tendría que saber de ambos mundos. Es el riesgo 2 del estudio (lógica duplicada en controlador y en Mac).
- *Elegir un camino por sesión (solo uno activo)*: cumple "usar el otro si falla", pero no "correr los dos a la vez" (decisión 3 del usuario) y la conmutación tarda lo que tarde el descubrimiento.
- *Enviar siempre por ambos caminos*: duplica el consumo de radio y de batería en moto. Se usa solo con calidad baja.

Modos existentes (`TransportMode`): `.gateway` (Auto) = dos caminos, por defecto; `.apple` = solo camino Multipeer; `.universal` = solo camino Network. Los dos últimos se conservan para depuración y recurso.

## Decisión 2: voz sobre UDP y servicio `_motobridge._udp` (por qué no `_tcp`)

**Elegido:** datagramas UDP y el tipo de servicio Bonjour `_motobridge._udp` (sin cambios).

Razones contra `_tcp`:
- TCP es un flujo ordenado y confiable. Una trama perdida bloquea todas las siguientes hasta retransmitir (bloqueo de cabeza de línea) y entrega audio atrasado que el jitter buffer ya debe descartar. Contradice "lo tardío se descarta, no se reintenta" y el envío no confiable que el código ya usa (`PeerBridgeSession.swift:256-268`, UDP en `LocalNetworkTransport.swift:80-86`).
- Android descubre solo `_motobridge._udp` (`net/LocalNetworkTransport.kt:28`) y la app publicada igual (`LocalNetworkTransport.swift:24`). Cambiar el tipo rompe el descubrimiento con ambos y con Mac (`UniversalTransport.swift`).
- Por convención de Bonjour, la etiqueta `_udp` o `_tcp` indica el protocolo de transporte del servicio. Anunciar `_tcp` y hablar UDP (o al revés) confunde a los clientes. Mantener la etiqueta `_udp` evita esa inconsistencia.
- La propuesta original del usuario dice `_monobridge._tcp`; ese nombre tampoco coincide con el real (`motobridge`).

`NSBonjourServices` ya contiene `_motobridge._tcp` y `_motobridge._udp` en iOS (`Info.plist:29-35`). Se conservan; `_motobridge._tcp` queda sin uso (no se quita para no tocar permisos innecesariamente).

Alternativas descartadas:
- *QUIC con datagramas (`QUIC.Datagrams` aparece en la interfaz de Network)*: añade TLS y estado de conexión; Android no lo tiene sin una biblioteca nueva. Reconsiderar con cifrado.
- *Servicio nuevo `_motobridge2._udp`*: no rompe nada, pero duplica el descubrimiento sin beneficio funcional. Se descarta mientras la versión de protocolo viaje en la presencia (spec 1).

Un detalle del descubrimiento (heredado de `PeerBridgeSession.swift:21-27`): dos nodos con el mismo nombre de servicio provocan colisión de nombre en Bonjour. El nombre del servicio se mantiene como `localName` más sufijo de 4 hex del `ID`, y la presencia sigue llevando el nombre real. Ningún lector baseline usa el nombre del servicio como nombre de rider salvo para identificar la conexión; la presencia (primera línea) manda para el radar. Verificar en la tarea 3 que Android y la baseline no muestran el sufijo.

## Decisión 3: API de iOS 26 y reglas de la capa Network

Verificado en el SDK local (`Network.swiftinterface`): `NetworkListener` (con `run` que entrega `NetworkConnection`), `NetworkBrowser` (con `run` que entrega endpoints), `NetworkConnection` (con `onStateUpdate`, `onPathUpdate`, `currentPath`, `remoteEndpoint`), `UDP`, `BonjourListenerProvider` y la opción de parámetros `peerToPeerIncluded(_:)`. La sesión WWDC25 250 los presenta con `async/await`. **No se verificó** la firma exacta de `NetworkBrowser` para Bonjour ni cómo se entregan los datagramas de un listener UDP; la tarea 1 es un prototipo que cierra esa duda antes de escribir el transporte completo.

Reglas de diseño del camino Network (independientes de la firma exacta):
- Un `NetworkListener` UDP con servicio Bonjour y P2P incluido; un `NetworkBrowser` Bonjour con P2P incluido.
- Una `NetworkConnection` por vecino y dirección. Una conexión entrante y una saliente al mismo vecino se colapsan por `ID` en el compuesto: se conserva la que abrió el extremo de `ID` menor y se cierra la otra tras 5 s de convivencia, para no tener conexiones fantasma.
- Cada lectura de datagrama alimenta el `LivenessTracker` del spec 2 (clave: vecino + camino).
- La concurrencia: cada conexión corre su lectura en una `Task` propia; el estado compartido (tabla de caminos) se protege con un `actor` o una cola serie. Se descarta mezclar GCD de `NWConnection` con `async/await` en el mismo estado.
- Un listener o navegador en `.failed` o `.waiting` se recrea con el retroceso del spec 2.

Alternativa descartada: *conservar la API clásica (`NWListener`/`NWBrowser`)*. Con mínimo iOS 26 no hay razón para mantener dos APIs, y la clásica es la que Apple considera heredada. Riesgo aceptado: la API nueva es joven y puede tener comportamientos distintos (por ejemplo en descubrimiento tras volver de segundo plano). Por eso la tarea 1 es un prototipo con criterios de salida y por eso Multipeer sigue vivo como red de seguridad.

## Decisión 4: identidad de vecino y asociación de caminos

Cada camino identifica conexiones con su propio id (`MCPeerID.displayName` o endpoint/servicio). El `ID` de 8 hex de la presencia (spec 1) es la identidad común. Tabla en el compuesto: `ID → {camino → conexión}`.

- Hasta recibir la primera presencia, la conexión es provisional y cuenta como un vecino aparte. Al llegar el `ID`, se colapsa al vecino existente si ya lo hay.
- Un vecino sin `ID` (baseline) se identifica por nombre (primera línea de presencia). Dos conexiones con el mismo nombre y sin `ID` se tratan como un vecino legacy con dos caminos, para los que rige R5.4.
- Un `ID` repetido con otra conexión viva en el mismo camino se trata como reinicio de la app del vecino: gana la más reciente.

Alternativa descartada: *derivar la identidad de MCPeerID*. TN3213 (citado en el estudio vía resumen de prensa) lo describe como un envoltorio de un número aleatorio; no es estable entre caminos.

## Decisión 5: elección de camino y envío

Función pura `PathSelector` (reloj inyectado), mismas reglas en iOS y Mac; Android no la necesita (tiene un solo camino hacia el iPhone) pero implementa la deduplicación y el armado compatibles.

Entradas por vecino: estado de liveness y `q` por camino (spec 2 y spec 4), `backgroundPathPreference`, estado de la app.

Reglas:
1. Primario = camino vivo con mayor `q`; empate: Network. Cambio de primario solo si el otro supera por 2 o más durante 3 s.
2. Si `backgroundPathPreference` para el estado actual dice `sí` para un camino y `no` para el otro, manda esa preferencia.
3. Redundancia: si el primario tiene `q` < 6 o `inestable`, la voz sale por ambos hasta que el primario se mantenga con `q` ≥ 7 durante 5 s (histéresis).
4. Caído (2 s sin paquetes): el camino sale de los destinos. Si no queda ningún camino, el vecino pasa a caído para el relay (spec 2).
5. Vecino sin `SEQ` o sin `DP`: un solo camino (el primario), y recepción solo de ese camino.
6. Control (keepalive, presencia): ambos caminos siempre (R4.4).

Alternativas descartadas:
- *Preferir siempre Network (o siempre Multipeer)*: sin datos de campo cuál es mejor; ambos usan la misma Wi-Fi P2P de Apple según un ingeniero de Apple (foro 831993), así que la diferencia depende del entorno (Wi-Fi compartido o hotspot, o P2P directo).
- *Elegir por latencia medida (RTT)*: UDP unidireccional no tiene RTT sin un protocolo de eco. No se añade.

## Decisión 6: dónde se deduplica

Se reutiliza `MeshRelay.processIncoming` (`MeshRelay.swift:56-75`), que ya implementa la caché de 2048 vistos con clave `originId` + `packetId`, pero se llama una sola vez, en el compuesto, antes de entregar al controlador. Con vecinos `SEQ` (spec 3) la cabecera de malla siempre está presente, así que todo paquete de voz tiene clave. Los paquetes de control por camino (keepalive, liveness) se consumen antes de la deduplicación porque son por camino y no se reenvían.

Si la prueba de capacidad (R5.5) muestra que 2048 no alcanza para 20 s con 5 orígenes a 50 paquetes por segundo (5 × 50 × 20 = 5000 entradas), se amplía a 8192. Es un cambio de una constante (memoria ≈ 8192 × 8 bytes más la lista de orden). Lo estimo suficiente sin cambio de estructura, pero se mide.

Alternativas descartadas:
- *Deduplicar por camino y luego otra vez al unir*: dos cachés con ventanas distintas dejan pasar duplicados.
- *Deduplicar solo por `packetId` de 32 bits sin origen*: dos orígenes distintos colisionan.

## Decisión 7: segundo plano y pantalla bloqueada

Se hereda el diseño del spec 2 (modo de fondo `audio`, `isIdleTimerDisabled` ya implementado en `NetworkBridgeController.swift:1310`, mantenimiento de sesión y reconexión). Este spec añade la prueba del camino Network con iOS 26 a la matriz del spec 2 (R7). Hasta tener resultados, ambos caminos permanecen abiertos en segundo plano y el compuesto no asume que uno sobrevive: si uno cae, usa el otro. Eso es justo la ventaja de correr ambos.

## Decisión 8: Android y Mac

**Android:** no tiene Multipeer ni AWDL; su único camino hacia un iPhone es UDP/NSD sobre Wi-Fi. No hay migración de API. Cambios: anunciar `DP` en `CAP`; usar el `ID` del spec 1 para asociar; asegurar deduplicación única antes del jitter buffer y del relay (el código de `MeshRelay.kt` ya deduplica); tolerar que un iPhone aparezca conectado dos veces por IP distinta (Wi-Fi y P2P no aplican a Android, pero un iPhone con VPN o doble interfaz sí puede); pruebas de interoperabilidad con el nuevo `NetworkBrowser` y `NetworkListener` (tarea 6).
**Mac:** `RelaySession.swift` (Multipeer) y `UniversalTransport.swift` (UDP) pasan al mismo `MultiPathTransport` compartido con iOS (archivo agregado a `sources` de MonoBridgeRelay en `project.yml`, como `MeshRelay.swift`). Mínimo macOS 26. El Mac conserva `beginActivity` (`RelaySession.swift:266`).

Alternativa descartada para Mac: *mantener macOS 14 con la API clásica*. Duplica el código de transporte para una sola aplicación interna; se prefiere un camino único.

## Archivos a modificar

- iOS: `project.yml` (deployment 26.0, sources Mac), `MotoBridge/Core/Network/AudioTransport.swift` (modos, eventos), nuevos `MultiPathTransport.swift`, `PathSelector.swift`, `NetworkFrameworkTransport.swift` (reemplaza a `LocalNetworkTransport.swift`; el viejo se elimina tras pasar la matriz), `PeerBridgeSession.swift` (aislado como camino, comentarios corregidos), `NetworkBridgeController.swift` (quita `gatewayTransport`, `wireGatewayTransport`, `:1073-1150`, `:1278-1284`), `Info.plist` (sin quitar servicios), `AudioDiagnosticsView.swift` (estado por camino), `NetworkBridgeView.swift` (estado de caminos en la UI).
- Android: `net/LocalNetworkTransport.kt` (`CAP=DP`, uso de `ID`), `BridgeController.kt`.
- Mac: `RelaySession.swift`, `UniversalTransport.swift` (reemplazado por el compartido), `MonoBridgeRelay/Info.plist`, `project.yml`.
- Docs: `PROTOCOL.md`, `KNOWN_LIMITATIONS.md`, `README.md`, `CHANGELOG.md`.

## Manejo de errores

| Operación | Falla | Tipo | El llamador recibe | Log |
|---|---|---|---|---|
| Crear `NetworkListener` | Puerto o permiso de red local | Recuperable | El camino Network se marca `no disponible`; Multipeer sigue; reintento con retroceso | `error` y evento |
| Crear `NetworkBrowser` | `.failed` o `.waiting` | Recuperable | Igual; el camino Network no descubre | `warning` |
| Crear sesión Multipeer | Falla de inicialización | Recuperable | El camino Multipeer se marca `no disponible`; Network sigue | `error` y evento |
| Ambos caminos no disponibles | Permiso de red local denegado | Fatal para la red | Estado `Sin conexión` con el mensaje de permisos existente | `error` |
| Conexión | Falla o `.cancelled` | Recuperable | Liveness del spec 2; el camino sale de destinos | `info` |
| Envío por un camino | Error de envío | Recuperable | Se cuenta; si el camino es el primario y falla 3 veces seguidas, cuenta como silencio de salida y se usa el secundario | `debug`; `warning` al 3.º |
| Asociación por `ID` | Dos conexiones con `ID` igual en el mismo camino | Recuperable | Gana la más reciente; la vieja se cierra | `info` |
| Paquete duplicado | Llega por ambos caminos | Esperado | Descartado; contador por camino | contador |
| Paquete sin cabecera con vecino `SEQ` | Inconsistencia | Recuperable | Descartado | `debug` |
| Colisión de nombre Bonjour | Servicio renombrado | Recuperable | Se identifica por `ID` de presencia | `debug` |
| Inicio con iOS < 26 | App no instalable | n/a | La tienda no ofrece la app (mínimo declarado) | n/a |

## Validación de entradas externas

| Entrada | Obligatoria | Tipo y límite | Si falla |
|---|---|---|---|
| Datagrama UDP recibido | Sí | Máximo 1400 bytes; mínimo 2 | Descartar y contar |
| Nombre de servicio Bonjour | Sí | Hasta 63 bytes UTF-8 | Truncar al anunciar; al leer, descartar si vacío |
| `ID` en presencia | No | 8 hex | Vecino legacy por nombre |
| Preferencia de camino de segundo plano | Sí (con valor por defecto) | `sí`/`no`/`desconocido` | Usar `desconocido` |
| Número de vecinos | Sí | Máximo 5 vecinos (no conexiones) | Rechazar el 6.º con el mensaje existente |

## Invariantes

- **Cada paquete de voz se entrega una sola vez.** Lo aplica la deduplicación única del compuesto, porque es la única capa que ve ambos caminos.
- **Hacia un vecino legacy solo hay un camino de envío.** Lo aplica `PathSelector` (regla 5), porque el vecino legacy no puede deduplicar.
- **El tope de 5 cuenta vecinos, no conexiones.** Lo aplica el compuesto, porque cada camino solo conoce sus conexiones.
- **Un fallo de un camino no detiene el otro.** Lo aplica el compuesto aislando los errores de cada hijo y sin compartir estado mutable entre ellos.
- **Multipeer queda aislado en una clase.** Lo aplica la estructura de módulos (R8.2).

## Testabilidad

Unitarias:
- `PathSelector` con tablas de calidad, histéresis, redundancia, vecino legacy, preferencia de segundo plano.
- Deduplicación con paquetes entregados por dos caminos simulados en todos los órdenes.
- Asociación por `ID`: provisional, colapso, reinicio.
- Tope de 5 vecinos con 2 caminos.
- Compuesto con dos hijos simulados: uno falla, el otro sigue.

Integración: dos instancias del camino Network en el mismo proceso por loopback (la parte de P2P y de Bonjour real requiere dispositivos).

Campo: matriz C1 (R7), conmutación de camino con medición de interrupción (R4.2, R4.3), 10 repeticiones de rejoin (R6.1), CPU en iPhone 11 (NF1), segundo plano (spec 2 R7).
