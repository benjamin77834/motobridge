# Diseño: mesh-smart-relay

## Visión general

Hoy cada nodo reenvía todo paquete nuevo a todos sus peers conectados, incluido el que se lo mandó, y la deduplicación evita bucles pero no el tráfico redundante. Este spec añade a cada nodo un conocimiento de topología de dos saltos (quién oye a quién y con qué calidad) y una función pura de decisión: dado un paquete nuevo, un nodo reenvía solo a los vecinos que aún no lo oyeron y solo si él es el mejor candidato para llegar a ellos. La calidad sale de los keepalives del spec 2, no de RSSI (que iOS no expone). Un mecanismo de reparación cubre las tablas desactualizadas, y la regla "fallar abierto" garantiza que ante la duda se reenvíe como hoy. El TTL máximo se queda en 6.

**Stack:** Swift en iOS y Mac (lógica compartida con `MeshRelay.swift`), Kotlin en Android. Sin dependencias nuevas. Funciones puras para decisión y tablas; el envío usa los transportes existentes con una API nueva de envío dirigido a vecinos.

## Decisión 1: cómo se conoce la topología

**Elegido:** vector de vecinos anunciado en la presencia de 2 s.

Líneas nuevas de presencia (solo se envían y se interpretan con `SR`):

| Línea | Contenido | Ejemplo |
|---|---|---|
| `NB=` | hasta 5 vecinos directos vivos: `ID:q`, `q` de 0 a 9 | `NB=1A2B3C4D:9,5E6F7A8B:6` |
| `HRD=` | hasta 4 `ID` de orígenes oídos directamente en los últimos 2 s | `HRD=1A2B3C4D,0F0F0F0F` |

`q` se calcula como `9 × (1 − pérdida)` redondeado, con pérdida = keepalives esperados que no llegaron en 4 s entre los 8 esperados, menos 3 si el vecino está `inestable` (spec 2), mínimo 0. Es la calidad con que el nodo anunciante recibe a ese vecino. No es potencia de señal: mide lo que importa para la voz (paquetes que llegan).

Como la presencia se retransmite por malla (hoy con TTL 6), cada nodo aprende las listas de sus vecinos y de los orígenes que alcanza, y construye una tabla `NB[id] = {vecino → q}` con antigüedad. Una entrada con más de 5 s de antigüedad se considera desactualizada (la presencia es cada 2 s).

Alternativas descartadas:
- *RSSI por peer*: no existe en la API pública de iOS (foro Apple 721067). `NEHotspotNetwork.signalStrength` mide la red a la que estás conectado y requiere entitlement (foro 751316).
- *Wi-Fi Aware con `WAPerformanceReport`*: requiere emparejado y su soporte en Android no está verificado.
- *Supresión por escucha (como Trickle o gossip con contador)*: Multipeer y las conexiones UDP unicast no dejan oír lo que un vecino reenvía a otro, así que no hay señal de supresión. Por eso se necesita la lista de vecinos.
- *Vector de distancia (saltos al origen)*: se deduce de `NB` y `HRD` cuando hace falta; no se anuncia aparte para no crecer el payload.

## Decisión 2: función de decisión de relay

Función pura `decide(paquete, S, O, ttl, vecinosVivos, tablaNB, tablaHRD, ahora) → lista de vecinos destino`. Misma lógica y mismos vectores de prueba en iOS, Android y Mac.

Pasos, por cada vecino directo vivo N de R:
1. Si N es S u O: omitir (R2).
2. Si N no tiene `SR`: se trata como legacy; se reenvía salvo que sea S u O (R2.4).
3. Si falta la entrada `NB` de S, de O o de N, o tiene más de 5 s: reenviar (falla abierta, R2.3).
4. Si N está en `NB[S]` o en `NB[O]`: omitir (N ya oyó el paquete directamente de quien lo transmitió).
5. Conjunto de candidatos C = {R} ∪ { X : X está en `NB[S]` ∪ `NB[O]` ∪ {S} y N está en `NB[X]` o X está en `NB[N]` }.
6. R es el elegido si su `q` hacia N (el valor de R en `NB[N]`) es el mayor del conjunto C; empate: `ID` menor. Con histéresis: si R ya fue el elegido para N con este origen en los últimos 2 s, sigue siéndolo salvo que otro candidato lo supere por 2 o más.
7. Si R es el elegido, N es destino.

TTL de salida = TTL de entrada − 1; TTL entrante > 6 se trata como 6; TTL ≤ 1 no se reenvía.

Alternativas descartadas:
- *Elegir solo por menor ID*: ignora la calidad real y concentra el relay en un nodo.
- *Reenviar con probabilidad p (gossip)*: el comportamiento deja de ser verificable y puede dejar a alguien sin voz.
- *Árbol de expansión por origen*: costoso de mantener con topología que cambia cada pocos segundos en moto.

## Decisión 3: reparación y falla abierta

Dos mecanismos de seguridad, porque las tablas de 2 s pueden estar desactualizadas en movimiento:
- **Falla abierta** (paso 3): si no se sabe, se reenvía.
- **Reparación:** cada vecino con `SR` anuncia en `HRD` los orígenes que oye directamente. Si R recibe voz del origen O (por S) y su vecino N no tiene a O en `HRD` durante 2 s, R pasa a reenviar a N los paquetes de O hasta que `HRD` de N incluya a O durante 2 s seguidos (R3). Evita que un candidato elegido que no reenvíe deje a N sin voz más de unos 2,5 s.

Contadores: reenviados, suprimidos por causa (ya cubierto, no soy el mejor, TTL agotado), duplicados, reparaciones y distribución de saltos (R8).

## Decisión 4: TTL máximo 6

Lo fija el arquitecto. Razones: el alcance de caravanas de hasta 6 motos es el caso de uso declarado (`MeshRelay.swift:18`); builds viejas calculan `hops = defaultTTL - ttl` con 6 (`MeshRelay.swift:51`, Android `MeshRelay.kt:42`), así que cambiarlo en una parte del grupo falsea el contador de saltos del radar; con relay selectivo el riesgo de inundación a 6 saltos baja porque cada nodo reenvía solo si es el mejor candidato. Con el tope de 5 conexiones el costo teórico de 6 saltos en baseline es de hasta ~5^6 paquetes en peor caso sin deduplicar, que la deduplicación y este spec reducen a ≤ 1 transmisión por nodo y paquete.

Revisión con datos: R8 define contadores y fecha de revisión tras la primera prueba de campo con al menos 4 dispositivos. Si los datos muestran que más del 95 % de los paquetes reciben a lo sumo 3 saltos, se puede proponer bajar a 4 o 5 para ahorrar batería. No se baja a 3 sin evidencia.

## Decisión 5: envío dirigido y modo gateway

Hoy `sendAudio` envía a todos los peers de un transporte. Hace falta enviar a un subconjunto: se añade al protocolo `AudioTransport` una operación de envío dirigido a una lista de ids de vecino (Multipeer: `send(_:toPeers:)`, UDP: conexiones filtradas). En modo gateway, el puente deja de reenviar el paquete original (`NetworkBridgeController.swift:1088,1148-1150`) y pasa por la misma función de decisión con TTL − 1; así Multipeer y UDP son simplemente "dos conjuntos de vecinos" para la función, y R6.2 queda garantizado por el paso 1.

Mac Relay ya reenvía entre Multipeer y UDP (`RelaySession.swift:490-491`) con una regla distinta; usa la misma función compartida.

La deduplicación por `originId` + `packetId` ya existe (`MeshRelay.swift:27,56-60`) y con el spec 3 la cabecera de malla está siempre presente con vecinos `SEQ`, así que también protege contra el doble camino del spec 5.

## Archivos a modificar

- iOS/Mac: `MotoBridge/Core/Network/MeshRelay.swift` (compartido; añadir la función de decisión y tablas, o un archivo nuevo `RelayPlanner.swift` junto a él y agregado a `sources` de MonoBridgeRelay en `project.yml`), `AudioTransport.swift` (envío dirigido), `PeerBridgeSession.swift`, `LocalNetworkTransport.swift`, `NetworkBridgeController.swift` (`wireTransport` y `wireGatewayTransport`, `:1073-1150`; `sendPresence` `:822-850`), `AudioDiagnosticsView.swift`.
- Android: `net/MeshRelay.kt` (`:10,42,61-66`), nuevo `net/RelayPlanner.kt`, `net/LocalNetworkTransport.kt` (envío dirigido), `BridgeController.kt` (`:344-358,396-402`).
- Mac: `RelaySession.swift` (`:408-415,490-491`), `UniversalTransport.swift` (envío dirigido).
- Docs: `PROTOCOL.md` (líneas `NB`/`HRD`, regla de relay), `README.md` de specs.

## Manejo de errores

| Operación | Falla | Tipo | El llamador recibe | Log |
|---|---|---|---|---|
| Parsear `NB`/`HRD` | Formato inválido o IDs repetidos | Recuperable | Se descarta la línea; la entrada queda sin actualizar (falla abierta al envejecer) | `debug` |
| `decide` | Tabla vacía o vecino sin entrada | Recuperable | Reenvía (falla abierta) | contador |
| Envío dirigido | Vecino ya no está conectado | Recuperable | Se omite y se cuenta; el liveness del spec 2 se encarga | `debug` |
| Envío dirigido | `send` devuelve error | Recuperable | Se cuenta; no se reintenta (voz tardía no sirve) | `debug` |
| Reparación | Bucle de reparaciones (N nunca incluye a O en `HRD`) | Recuperable | Tope de reparación de 10 s por par (O, N) y luego se espera 30 s | `warning` |
| Presencia mayor de 256 bytes | Excede el límite | Recuperable | Se recortan `HRD` y luego `NB` hasta caber | `debug` |

Ningún error de este spec es fatal ni se muestra al usuario.

## Validación de entradas externas

| Entrada | Obligatoria | Tipo y límite | Si falla |
|---|---|---|---|
| `NB` | No | Hasta 5 pares `ID(8 hex):q(0-9)` | Descartar línea |
| `HRD` | No | Hasta 4 IDs de 8 hex | Descartar línea |
| TTL de malla | Sí | 0 a 255; se trata como máximo 6 | Valores mayores se recortan a 6 |
| `originId` | Sí | No cero | Descartar paquete |
| Entradas de tabla | n/a | Máximo 32 orígenes, 5 vecinos por origen | Se expulsa la más antigua |

## Invariantes

- **Ningún paquete vuelve a su emisor S ni a su origen O.** La aplica `decide` (paso 1), una sola función compartida, y no cada transporte.
- **Ante información faltante o vieja se reenvía.** La aplica `decide` (paso 3). Es mejor tráfico de más que un rider sin voz.
- **Un vecino sin `SR` nunca queda sin voz.** La aplica `decide` (paso 2); su comportamiento es el de la baseline.
- **Ningún paquete se procesa dos veces.** La aplica la deduplicación de `MeshRelay` por `originId` + `packetId`, antes de decidir.

## Testabilidad

Unitarias (sin dispositivos), con el mismo conjunto de topologías en XCTest y JUnit:
- Un simulador de topologías en memoria (grafo con calidades por arista, pérdida configurable, reloj falso) que ejecuta `decide` en cada nodo y cuenta transmisiones, para R4.1 a R4.5.
- Vectores de `decide` con entradas y salidas esperadas (paso a paso).
- Parseo y armado de `NB` y `HRD`; cálculo de `q` con series de keepalives.
- Reparación con candidato que no reenvía.

Integración: dos transportes UDP locales y un transporte Multipeer simulado en el controlador (R6.1, R6.3).
Campo: 3 y 4 dispositivos en cadena y en estrella con contadores de R8; un paso con la baseline en el grupo (R9.1).
