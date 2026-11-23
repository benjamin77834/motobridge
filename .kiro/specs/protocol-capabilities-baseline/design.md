# Diseño: protocol-capabilities-baseline

## Visión general

El protocolo actual no tiene versión ni forma de saber quién envió un paquete. Este spec añade tres líneas al payload de presencia (versión, identidad y capacidades), una tabla en memoria que las recuerda, y un cambio de firma en los callbacks de transporte para saber de qué vecino directo llegó cada paquete. Con eso, los specs siguientes activan formatos nuevos solo con los pares que los entienden. No se toca el formato de audio, la cabecera de malla ni el tipo de canal.

**Stack (bloqueado al aprobar):** Swift y SwiftUI en iOS y macOS, Kotlin en Android. Sin librerías nuevas. Deployment target sin cambios en este spec (iOS 17.0, macOS 14.0, Android minSdk 26); el salto a iOS 26 ocurre en el spec 5.

## Decisión 1: dónde viajan las capacidades

**Elegido:** líneas extra en el payload de presencia existente (`VoiceChannelType.presence`), después del nombre. Precedente: `ALT=` y `BAT=` (`NetworkBridgeController.swift:802-816`). El parser de iOS ya ignora líneas desconocidas.

Alternativas descartadas:
- *Tipo de canal nuevo (valor 8)*: las apps viejas reproducen un tipo desconocido como audio crudo y suena un clic (`PROTOCOL.md` §9; `VoiceChannel.swift:79-80`). Viola C3.
- *TXT record de Bonjour*: permitiría conocer capacidades antes de conectar, pero Multipeer tiene su propio mecanismo (`discoveryInfo`) y Android NSD lee atributos de forma distinta por fabricante. Tres mecanismos para lo mismo. Además no cubre orígenes lejanos que se aprenden por presencia retransmitida. Se deja como mejora futura.
- *Cabecera de versión en cada paquete*: rompe a las apps viejas y la baseline no tiene campo de versión.

## Decisión 2: formato de las líneas

Payload de presencia (UTF-8, separador `\n`):

| Línea | Obligatoria | Contenido |
|---|---|---|
| 1 | sí | Nombre del rider (sin cambios) |
| `ALT=` / `BAT=` | no | Modo rescate (sin cambios) |
| `PV=` | sí desde esta build | Entero decimal, versión de protocolo. 2 desde este spec |
| `ID=` | sí desde esta build | 8 hex mayúsculas, `originId` de malla del nodo |
| `CAP=` | sí desde esta build | Tokens separados por coma, sin espacios |

Tokens definidos (cada spec activa el suyo):

| Token | Lo activa | Significado |
|---|---|---|
| `HB` | spec 2 | Acepta keepalive de 500 ms y umbral de caída de 2 s |
| `SEQ` | spec 3 | Acepta audio v2: cabecera de malla siempre presente y secuencia de audio |
| `OPUS` | spec 3 | El nodo puede codificar y decodificar Opus de forma fiable |
| `SR` | spec 4 | Anuncia lista de vecinos y acepta relay selectivo |
| `DP` | spec 5 | Soporta doble camino con deduplicación y elección de camino |

`TEST` existe solo en builds de depuración y sirve para la prueba R5.2.

Reglas de parseo: una línea desconocida se ignora; un token desconocido se ignora; `PV` no numérico se trata como ausente; el payload se limita a 512 bytes antes de decodificar (más se descarta y se cuenta).

`ID` reutiliza `MeshRelay.localOriginId` en lugar de un identificador nuevo para que la clave de deduplicación (`originId` + `packetId`) y la identidad que se anuncia sean la misma cosa. No se persiste entre sesiones por dos motivos: un reinicio reinicia `packetId` desde 0, y un `originId` repetido haría que los vecinos descarten los paquetes nuevos como ya vistos (caché de 2048, `MeshRelay.swift:27`).

## Decisión 3: identificar al vecino emisor

Hoy el callback de recepción entrega solo los bytes (`AudioTransport.swift`, `onAudioData`). Sin saber quién mandó el paquete no se puede decidir cómo interpretarlo cuando dos formatos conviven, ni medir liveness por vecino, ni elegir siguiente salto.

**Elegido:** el callback de audio recibido pasa a llevar `(datos, idDeVecinoDirecto)`. El id es `TransportPeer.id` (hoy el nombre de display en Multipeer y el nombre del servicio Bonjour o el endpoint entrante en UDP). Cambios equivalentes en `LocalNetworkTransport.kt` y `UniversalTransport.swift`.

Alternativa descartada: *poner el id de vecino dentro del paquete*. Un vecino legacy no lo pondría y el campo sería falsificable por un tercero.

Limitación conocida: en UDP, el id de una conexión entrante es provisional (`in-<endpoint>`, `LocalNetworkTransport.swift:~99`) hasta que llegue su presencia. La tabla de capacidades debe vincular `idDeVecino` con `ID` al recibir la primera presencia por ese vecino. Hasta entonces el vecino es legacy.

## Decisión 4: dónde viven las reglas

Lógica pura (parseo de presencia, tabla de capacidades, contador de legacy) en archivos nuevos sin dependencias de plataforma:

- iOS y Mac: `MotoBridge/Core/Network/PeerCapabilities.swift`, compilado también en el target Mac Relay agregándolo a `sources` de `project.yml`, igual que `MeshRelay.swift` (`project.yml:62-69`).
- Android: `android/app/src/main/java/com/motobridge/android/net/PeerCapabilities.kt`.

Los tres proyectos deben producir las mismas líneas y el mismo parseo. Se verifica con un conjunto común de vectores de prueba en un archivo de texto (`.kiro/specs/protocol-capabilities-baseline/vectors/presence-vectors.txt`) que las tres suites leen o copian.

Archivos a tocar:

- iOS: `NetworkBridgeController.swift` (`sendPresence`, `parsePresence`, `wireTransport`, `wireGatewayTransport`), `AudioTransport.swift` (firma del callback), `PeerBridgeSession.swift` y `LocalNetworkTransport.swift` (entregar id de vecino), `MeshRelay.swift` (exponer `localOriginId` ya existente), `AudioDiagnosticsView.swift` (contador legacy).
- Android: `BridgeController.kt` (presencia), `net/LocalNetworkTransport.kt` (id de vecino), `net/PeerCapabilities.kt` (nuevo), `build.gradle` (JUnit de pruebas).
- Mac: `RelaySession.swift` (presencia en `:408-415`, parseo en `:658`), `UniversalTransport.swift` (id de vecino), `project.yml` (sources).
- Docs: `PROTOCOL.md`, `KNOWN_LIMITATIONS.md`.

## Decisión 5: ventana de transición y retiro de C1 a C4

Decisión del usuario: las versiones nuevas pueden forzar la actualización. Aun así, el rollout por TestFlight no es instantáneo, así que la compatibilidad rige solo hasta cumplir las tres condiciones de R8.2. Se elige un criterio verificable (contador local más confirmación humana) porque no hay telemetría remota y no se añade, por privacidad.

Consecuencia que el usuario debe conocer: los iPhone XS, XS Max y XR no pueden instalar iOS 26 (spec 5). Esos dispositivos quedarán en una build antigua que no tendrá `PV` 2. Al retirar la compatibilidad no podrán entrar a grupos con builds nuevas.

## Manejo de errores

| Operación | Falla | Tipo | El llamador recibe | Log |
|---|---|---|---|---|
| Decodificar presencia | Bytes no UTF-8 en línea 1 | Recuperable | Presencia descartada, nada cambia en el radar | `debug` con conteo |
| Decodificar presencia | Línea 1 vacía | Recuperable | Descartada (igual que hoy, `NetworkBridgeController.swift:804-805`) | `debug` |
| Decodificar presencia | Más de 512 bytes | Recuperable | Descartada | `warning` una vez por vecino y por minuto |
| Parsear `PV` | No numérico o negativo | Recuperable | `PV` ausente = legacy | `debug` |
| Parsear `ID` | No son 8 hex | Recuperable | `ID` ausente; el vecino sigue siendo legacy para funciones que lo requieran | `debug` |
| Parsear `CAP` | Token desconocido | Recuperable | Token ignorado | ninguno |
| Tabla | Más de 32 orígenes | Recuperable | Se expulsa el menos reciente | `debug` |
| Callback con id de vecino | Vecino ya no existe en el transporte | Recuperable | Paquete se procesa con id `unknown` y capacidades legacy | `debug` |

Ningún fallo de este spec es fatal ni se muestra al usuario.

## Validación de entradas externas

| Entrada | Obligatoria | Tipo y límite | Si falla |
|---|---|---|---|
| Línea 1 de presencia | Sí | UTF-8, 1 a 64 bytes | Descartar presencia |
| `PV` | No | Entero 0 a 255 | Tratar como ausente |
| `ID` | No | Exactamente 8 caracteres hex | Tratar como ausente |
| `CAP` | No | Máximo 128 bytes, tokens de 1 a 8 caracteres `A-Z0-9` | Ignorar los tokens inválidos |
| Payload completo | Sí | Máximo 512 bytes | Descartar |

## Invariantes y dónde se aplican

- **Una presencia nueva nunca cambia la primera línea.** La aplica la función que arma la presencia (una por plataforma) y la prueba de vectores R1.1. Está en esa capa porque es el único punto que escribe el payload.
- **Un par sin capacidad declarada se trata como legacy.** La aplica la tabla de capacidades (consulta por defecto = falso), no cada llamador, para que ningún spec posterior pueda olvidar la degradación.
- **Los tres proyectos parsean igual.** La aplican los vectores de prueba compartidos, porque las tres bases de código son independientes.

## Testabilidad

Pruebas unitarias (sin dispositivos):
- Parseo y armado de presencia con los vectores comunes, en XCTest (`MotoBridgeTests`), JUnit (`android/app/src/test`, nuevo) y sobre el código compartido para Mac.
- Tabla de capacidades: altas, bajas, expulsión, consulta "todos soportan X".
- Prueba de caracterización: presencia baseline sin las líneas nuevas sigue produciendo el mismo rider.

Pruebas de integración y de campo (con dispositivos):
- Matriz C1 contra la build baseline (R7).
- Verificación de A1: enviar una presencia con líneas desconocidas desde iOS a Android y a Mac y mirar que el radar no se rompe.

No requiere prueba en carretera.

## Riesgos y alternativas

- Si A1 es falso en Android o Mac (el parser falla con líneas extra), la tarea 1 lo detecta antes de implementar. Plan: añadir tolerancia en Android y Mac primero en una build previa y dejar las líneas nuevas apagadas hasta que esa build esté en todos los testers.
- La presencia crece de ~25 a ~80 bytes y se retransmite por malla cada 2 s por nodo: tráfico de control aceptable a 2 s. Se vuelve a medir en el spec 2.
