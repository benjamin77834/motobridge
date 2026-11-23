# Requisitos: apple-transport-network-framework

## Objetivo

Subir el mínimo a iOS 26 y macOS 26, reconstruir el transporte UDP sobre la API nueva de Network framework (`NetworkConnection`, `NetworkListener`, `NetworkBrowser`) y hacer que Multipeer Connectivity y Network framework corran **a la vez** como dos caminos hacia el mismo vecino. Cuando un camino no esté disponible o falle, el otro lo reemplaza solo. Los duplicados entre caminos se eliminan con la deduplicación `originId` + `packetId` que ya existe. Android y Mac Relay participan en el mismo spec.

## Dependencias

- Spec 1 (capacidades, `ID`, id de vecino).
- Spec 2 (liveness por camino, reintentos, resultados de la matriz de segundo plano).
- Spec 3 (cabecera de malla siempre presente con pares `SEQ`: necesaria para deduplicar entre caminos).
- Spec 4 (la función de decisión de relay trata los dos caminos como un solo vecino).

## Decisiones del usuario que fijan este spec

- D1. iOS mínimo 26 (el usuario no ve problema). Se usan `NetworkConnection`, `NetworkListener` y `NetworkBrowser`.
- D2. Las versiones nuevas pueden obligar a actualizar a todos; C1 a C4 siguen solo durante la transición (ver README, fecha de retiro).
- D3. Multipeer y Network corren ambos a la vez; si uno falla, se usa el otro.
- D4. Android y Mac se migran junto con iOS.
- D5. Voz sobre UDP (no TCP). Se conserva el servicio Bonjour `_motobridge._udp`.

## Efecto de subir el mínimo a iOS 26 (riesgo aceptado por el usuario)

iOS 26 exige un iPhone con chip A13 Bionic o posterior y al menos 3 GB de RAM (fuente: [Wikipedia, iOS 26, sección Supported devices](https://en.wikipedia.org/wiki/IOS_26), que cita a Apple; la página de compatibilidad de apple.com no pudo leerse de forma automática, así que se debe confirmar a mano en https://www.apple.com/ios/ios-26/. Apoyo oficial parcial: los avisos de seguridad de Apple de iOS 26.2 y 26.3 listan como destino "iPhone 11 and later", [Apple, iOS 26.3 y iPadOS 26.3](https://support.apple.com/en-gw/126346)). Quedan **sin actualización** de la app:

| Modelo | Chip | Estado con iOS 26 |
|---|---|---|
| iPhone XS | A12 | No compatible |
| iPhone XS Max | A12 | No compatible |
| iPhone XR | A12 | No compatible |

Los iPhone 11, 11 Pro, 11 Pro Max, SE (2.ª generación) y posteriores sí son compatibles. Modelos anteriores al XS ya no reciben la app actual por su mínimo iOS 17 (no se verifica aquí el detalle). El usuario confirmó que **sí usa iPad** (`TARGETED_DEVICE_FAMILY` "1,2" en `project.yml`) y aceptó que los modelos sin iPadOS 26 queden fuera. Según el mismo aviso de seguridad de Apple ([iOS 26.3 y iPadOS 26.3](https://support.apple.com/en-gw/126346)), iPadOS 26 llega a: iPad Pro 12,9 pulgadas de 3.ª generación y posteriores, iPad Pro 11 pulgadas de 1.ª generación y posteriores, iPad Air de 3.ª generación y posteriores, iPad de 8.ª generación y posteriores, e iPad mini de 5.ª generación y posteriores. Un iPad que no esté en esa lista no puede actualizar la app a la build con mínimo 26 (por ejemplo el iPad de 7.ª generación, según [un hilo de la comunidad de Apple](https://discussions.apple.com/thread/256180462), fuente no oficial para ese modelo). La lista oficial completa por modelo y la de iPhone siguen por confirmar en las páginas de compatibilidad de apple.com, que no se pudieron leer de forma automática.

Consecuencias:
- Un rider con iPhone XS, XS Max o XR queda en la última build con mínimo iOS 17. Cuando se retire la compatibilidad (spec 1, R8), esa build no podrá unirse a grupos con builds nuevas.
- Mac Relay sube a macOS 26. Según Wikipedia, macOS Tahoe es la última versión que soporta Macs Intel y solo algunos modelos (2020 iMac, 16" MacBook Pro 2019, 13" MacBook Pro 2020 de cuatro puertos y Mac Pro 2019, además de Apple silicon). Macs más antiguos quedan sin actualización del Relay. **Aceptado por el usuario** (README, respuesta 3).
- Android no se ve afectado por el mínimo de iOS. `minSdk` sigue en 26.

## Supuestos

- A1. La API nueva solo existe en iOS/macOS 26.0 o posterior. Verificado en el SDK local: el archivo `Network.swiftinterface` marca `NetworkBrowser`, `NetworkListener`, `NetworkConnection`, `UDP` y `BonjourListenerProvider` como `iOS 26.0`, y existe `peerToPeerIncluded(_:)` para activar Wi-Fi peer-to-peer. `MCSession` está marcada `API_DEPRECATED("Use Network Framework instead", ... ios(7.0, 27.0))` en el SDK local.
- A2. **Xcode de referencia: 27.2.1** (fijado por el usuario). El Xcode instalado en la máquina donde se escribieron estos specs informa `Xcode 27.0 (27A266a)`; es una diferencia anotada, no un bloqueo. La tarea 1 registra qué Xcode usa el build real. No cambia el diseño pero sí qué advertencias aparecen.
- A3. No se encontró fecha de eliminación de Multipeer; hoy es una deprecación de compilación, no de ejecución.
- A4. El transporte UDP actual de iOS ya usa Network framework clásico (`NWListener`, `NWBrowser`, `NWConnection`) con `includePeerToPeer = true` y habla con Android (`LocalNetworkTransport.swift:90-188`). Lo nuevo es (a) reescribirlo con la API de iOS 26 y (b) que trabaje junto con Multipeer como caminos del mismo vecino en lugar de como dos mundos separados que hoy se unen por un puente (`NetworkBridgeController.swift:1073-1150`).
- A5. Android no puede unirse a la red Wi-Fi peer-to-peer (AWDL) de Apple. Android ↔ iPhone sigue necesitando Wi-Fi o hotspot compartido.

## Requisitos funcionales (EARS)

### R1. Mínimos de plataforma

EL SISTEMA DEBERÁ declarar iOS 26.0 y macOS 26.0 como despliegue mínimo y retirar el código que solo existía para iOS 17 a 25.

Criterios de aceptación:
1. R1.1 `project.yml` declara `deploymentTarget iOS: "26.0"` y macOS `"26.0"`; el proyecto compila con Xcode 27 sin errores.
2. R1.2 Ninguna rama `#available(iOS 26, *)` queda en el código nuevo del transporte.
3. R1.3 La documentación (`README.md`, `KNOWN_LIMITATIONS.md`, página de la tienda si cita el mínimo) menciona iOS 26 y los modelos sin soporte (tabla de arriba).
4. R1.4 La advertencia de deprecación de Multipeer no rompe el build: no hay `SWIFT_TREAT_WARNINGS_AS_ERRORS` ni `-warnings-as-errors` activos para esos targets (se verifica en la tarea 1).

### R2. Transporte Network con la API de iOS 26

EL SISTEMA DEBERÁ ofrecer un transporte `AudioTransport` basado en `NetworkListener`, `NetworkBrowser` y `NetworkConnection` sobre UDP, que anuncie y busque el servicio Bonjour `_motobridge._udp` en el dominio `local.` con Wi-Fi peer-to-peer incluido.

Criterios de aceptación:
1. R2.1 iPhone ↔ iPhone, iPhone ↔ Mac y iPhone ↔ Android conectan y tienen audio bidireccional usando solo este camino (Multipeer desactivado por ajuste de depuración).
2. R2.2 El nombre del servicio y su tipo son idénticos a los de la baseline (`_motobridge._udp`, `local.`): una build baseline y la nueva se descubren mutuamente (C1).
3. R2.3 `NSBonjourServices` conserva `_motobridge._udp` y `_motobridge._tcp` (ya declarados) en `MotoBridge/Resources/Info.plist` y `_motobridge._udp` en `MonoBridgeRelay/Info.plist`; no se quita ninguna entrada.
4. R2.4 El camino aplica el tope de 5 vecinos y el desempate por `ID` del spec 2.
5. R2.5 El camino no usa TCP ni streams para voz. Cada trama es un datagrama (ver diseño, decisión 2).

### R3. Dos caminos a la vez

MIENTRAS el modo sea Auto, EL SISTEMA DEBERÁ ejecutar Multipeer y Network a la vez (descubrir, anunciar y conectar por ambos) y tratar las conexiones de un mismo vecino por ambos caminos como un solo vecino.

Criterios de aceptación:
1. R3.1 Dos iPhones nuevos en la misma red muestran una sola entrada en el radar y en la lista de conectados aunque estén conectados por los dos caminos. El conteo de vecinos para el tope de 5 cuenta vecinos, no conexiones.
2. R3.2 La tabla de caminos asocia cada conexión de transporte con el `ID` del vecino al recibir su primera presencia; antes de eso el vecino es provisional y se colapsa al aparecer el `ID`.
3. R3.3 Los modos `.apple` (solo Multipeer) y `.universal` (solo Network) siguen existiendo como ajuste de depuración y de recurso; el modo por defecto sigue siendo `.gateway`/Auto (`NetworkBridgeController.swift:38,1278-1284`), ahora con la semántica de este requisito.
4. R3.4 Con un vecino sin `DP` (build baseline), el sistema usa exactamente un camino hacia él (ver R5.4).

### R4. Selección y unión de camino

PARA cada vecino con dos caminos vivos, EL SISTEMA DEBERÁ enviar voz por el camino primario, elegido por calidad medida; SI el camino primario se declara caído o su calidad baja de 6, ENTONCES EL SISTEMA DEBERÁ enviar voz por ambos caminos hasta que se recupere.

Criterios de aceptación:
1. R4.1 Camino primario = el de mayor `q` (spec 4, R1.2); empate: Network. Solo cambia si el otro supera al primario por 2 o más durante 3 s seguidos (histéresis).
2. R4.2 Si el camino primario se marca caído (spec 2, 2 s), la voz sale por el secundario desde el mismo instante en que se marca caído y sin intervención del usuario. Con ambos caminos activos en la prueba, apagar uno deja audio continuo salvo la ventana de detección: la interrupción medida es ≤ 2,6 s.
3. R4.3 Mientras la calidad del primario sea menor que 6 o esté `inestable`, la voz sale por ambos caminos (envío redundante) y el receptor deduplica. La interrupción medida tras apagar el primario en ese estado es ≤ 0,5 s.
4. R4.4 Keepalives y presencia salen siempre por ambos caminos para que ambas liveness estén vigentes.
5. R4.5 Si uno de los dos transportes falla al iniciar (permiso, error de listener, `.failed`), el otro sigue operando y el sistema reintenta el fallido con el retroceso del spec 2; el rider ve en eventos qué camino está activo.
6. R4.6 Un vecino que solo existe por un camino (por ejemplo Android) usa ese camino y no genera errores por el camino ausente.
7. R4.7 La configuración `backgroundPathPreference` del spec 2 prevalece sobre la regla de calidad cuando la app está en segundo plano y la celda correspondiente tiene un valor distinto de `desconocido`.

### R5. Sin paquetes duplicados

EL SISTEMA DEBERÁ entregar al reproductor y al relay cada paquete (`originId`, `packetId`) una sola vez aunque llegue por ambos caminos.

Criterios de aceptación:
1. R5.1 Una única instancia de deduplicación recibe los paquetes de todos los caminos antes del jitter buffer, del reproductor y del relay.
2. R5.2 Prueba: el mismo paquete entregado por los dos caminos produce una reproducción y un reenvío, en cualquier orden de llegada.
3. R5.3 Un paquete que llegó por el camino A y se reenvía por el camino B hacia el origen o hacia quien lo envió se descarta (spec 4, R6.2).
4. R5.4 Hacia un vecino sin `SEQ` o sin `DP` el envío usa un solo camino (primario) y el sistema solo acepta audio de ese vecino por ese camino; el audio del otro camino se descarta y se cuenta (hoy un vecino legacy no puede deduplicar).
5. R5.5 La caché de vistos (2048 entradas) cubre al menos 20 s de tráfico a 50 paquetes por segundo y por origen con 5 orígenes; si no, se amplía (prueba de capacidad).
6. R5.6 Los paquetes de presencia y keepalive no se reenvían; los contadores diferencian duplicados por camino.

### R6. Rejoin automático por ambos caminos

Criterios de aceptación:
1. R6.1 Cuando un vecino se aleja y vuelve, el camino que lo vea primero lo reconecta sin intervención; el segundo camino se une cuando se descubra. Medición con 10 repeticiones por combinación (iPhone↔iPhone, iPhone↔Mac): p90 ≤ 8 s hasta voz en el primer camino.
2. R6.2 `NetworkBrowser` reevalúa resultados al reaparecer el servicio; si no lo hace en una prueba, el sistema reinicia el navegador a los 5 s sin vecino (resultado de la tarea 3).
3. R6.3 El comportamiento con la pantalla bloqueada se prueba para el camino Network con iOS 26 y se registra en la matriz del spec 2 (R7.1).

### R7. Compatibilidad con la app publicada, Android y Mac

Criterios de aceptación:
1. R7.1 Matriz C1 completa: nueva ↔ baseline, nueva ↔ Android (build baseline y nueva), nueva ↔ Mac (baseline y nueva); en cada combinación, audio bidireccional.
2. R7.2 Una build baseline iPhone que solo ve el servicio `_motobridge._udp` y `mbapple` sigue conectando a un nodo nuevo por al menos uno de los dos.
3. R7.3 Con un nodo baseline en el grupo, no se oye audio duplicado (eco) en ningún participante durante 10 min.

### R8. Plan de retiro de Multipeer

Criterios de aceptación:
1. R8.1 Este spec no retira Multipeer. El README define las condiciones de retiro: (a) la matriz de segundo plano muestra que Network cubre todos los casos que cubría Multipeer; (b) dos builds de TestFlight consecutivas sin regresión atribuible al camino Network; (c) los iPhone con iOS < 26 ya no están en el grupo (retiro de compatibilidad, spec 1 R8); (d) aprobación escrita del usuario.
2. R8.2 El código de Multipeer queda aislado detrás de una sola clase para poder borrarse en un solo cambio.

### R9. Seguridad y permisos

Criterios de aceptación:
1. R9.1 El nivel de cifrado no empeora: Multipeer sigue con el nivel actual (`.optional`) y Network sigue en claro como la baseline. Mejorar el cifrado de extremo a extremo es el spec 7 `audio-encryption`, que se aplica en la capa de aplicación y cubre los dos caminos sin cambiar este nivel.
2. R9.2 Los textos de permiso de red local existentes se conservan.

## Requisitos no funcionales

- NF1. Con ambos caminos activos y un vecino, el uso adicional de CPU respecto a un solo camino es ≤ 10 puntos porcentuales en iPhone 11 durante voz continua.
- NF2. El ancho de banda extra del modo redundante (R4.3) no supera el doble del flujo de voz del primario (≈ 24 kbps de carga útil más cabeceras) por vecino y solo mientras la calidad del primario sea baja.
- NF3. Sin dependencias de terceros nuevas.

## Fuera de alcance

- Wi-Fi Aware, `WAPerformanceReport`.
- Cifrado nuevo de audio (spec 7 `audio-encryption`; DTLS o PSK de transporte no se usan).
- Un tercer camino (Bluetooth, hotspot automático).
- Retirar Multipeer.
- Cambiar el puerto o el nombre del servicio Bonjour.
