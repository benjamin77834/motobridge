# Specs de Mono Bridge: malla, voz y transporte

Origen: `.agents/tasks/ios-mesh-network-framework-study.md` más las decisiones del usuario. Solo documentos; no hay código de implementación. Formato Kiro: `requirements.md` (EARS con criterios numerados), `design.md`, `tasks.md` por carpeta. Antes de este directorio no existía `.kiro/specs/`, así que no hay convenciones previas que respetar y no se sobrescribió nada.

## Orden y dependencias

| # | Carpeta | Objetivo | Depende de |
|---|---|---|---|
| 1 | `protocol-capabilities-baseline` | Versión, identidad y capacidades por par; documentación alineada; retiro de compatibilidad | Ninguna |
| 2 | `link-liveness-heartbeat` | Keepalive 500 ms, caída a 2 s, rejoin automático, enlace con pantalla bloqueada, prueba de segundo plano | 1 |
| 3 | `voice-pipeline-opus-jitter` | Opus 24 kbps, 20 ms, secuencia, jitter buffer 60 a 120 ms, ocultación de pérdida | 1 |
| 4 | `mesh-smart-relay` | Relay selectivo por calidad medida, TTL 6, topología mixta | 1, 2, 3 |
| 5 | `apple-transport-network-framework` | iOS/macOS 26, Network framework y Multipeer a la vez, dedup entre caminos | 1, 2, 3, 4 |
| 6 | `hotspot-rider-guide` | Guía "Maximizar compatibilidad" | Ninguna (puede ir en cualquier momento) |

Los specs 2 y 3 son independientes entre sí en lo técnico. El spec 6 es el de menor riesgo y se puede publicar primero. Cada spec trae tareas para iOS, Android y Mac Relay.

## Decisiones del usuario aplicadas

1. iOS mínimo 26 (Xcode 27). Efecto y modelos afectados: spec 5, requirements. Marcado como riesgo aceptado.
2. Las versiones nuevas pueden obligar a actualizar. C1 a C4 rigen solo durante la transición. Retiro: spec 1, R8.
3. Multipeer y Network a la vez, con respaldo automático y deduplicación por `originId` + `packetId`: spec 5 (R3 a R5, decisiones 1, 5 y 6).
4. Android y Mac se actualizan junto con iOS: tareas por plataforma en cada spec.
5. TTL máximo 6 (decisión del arquitecto, spec 4); voz sobre UDP y servicio `_motobridge._udp` conservado, con la explicación de por qué no `_tcp` (spec 5, decisión 2).
6. Topología mixta (caravana, grupos a la vista del líder, hotspot): spec 4, R4 y R5.
7. Pantalla bloqueada, enlace activo y rejoin: spec 2, R4 y R6; prueba en dispositivo en segundo plano: spec 2, R7 y tarea 6.
8. Sin RSSI por peer: la métrica es calidad medida por la app (spec 4, decisión 1).

## Criterios de compatibilidad transitorios (C1 a C4)

- C1. Nueva y última build publicada o de TestFlight conectan y se oyen en iOS↔iOS, iOS↔Android, iOS↔Mac y Android↔Android.
- C2. Todo cambio de formato se anuncia por capacidad y se degrada al formato actual.
- C3. Ningún tipo de canal nuevo sin comprobar que las apps viejas no lo reproducen como clic.
- C4. Cada spec cubre iOS, Android y Mac, o dice por qué no aplica.

**Cuándo se retiran:** cuando (a) todos los testers del grupo confirmen una build con protocolo 2 o mayor, (b) el contador local de peers legacy marque 0 durante 14 días seguidos y (c) el usuario lo apruebe por escrito (spec 1, R8.2). Hasta entonces el código legacy queda en rutas `Legacy*` para borrarlo de una vez. Los iPhone XS, XS Max y XR (sin iOS 26) quedan fuera de los grupos nuevos cuando eso ocurra.

## Retiro de Multipeer (no está en estos specs)

Se retira en un spec futuro cuando se cumplan: la matriz de segundo plano muestra que Network cubre lo que cubría Multipeer; dos builds de TestFlight seguidas sin regresión del camino Network; ya no hay iPhone con iOS < 26 en el grupo; y el usuario lo aprueba por escrito. Multipeer está deprecado en el SDK de Xcode 27 (`API_DEPRECATED ... ios(7.0, 27.0)`), pero hoy es una advertencia de compilación y no se encontró fecha de eliminación.

## Revisión del TTL

El TTL se queda en 6. Los contadores del spec 4 (R8) alimentan una revisión tras la primera prueba de campo con al menos 4 dispositivos. Fecha de revisión: por fijar al terminar esa prueba.

## Preguntas abiertas (no se inventó ningún dato)

1. **Build baseline.** ¿Qué commit o build de TestFlight es "la última publicada"? Se propuso `f494455` por ser el HEAD actual. Cambia la matriz C1.
2. **Latencia y rejoin.** Metas propuestas, sin confirmar: voz boca a oído ≤ 250 ms con 1 salto y ≤ 400 ms con 3 saltos (spec 3), rejoin p90 ≤ 8 s (specs 2 y 5). ¿Se aceptan?
3. **macOS 26 para Mac Relay.** Se asumió que sube a macOS 26 igual que iOS. Los Macs que no soportan Tahoe quedan sin actualización del Relay. ¿Se acepta?
4. **iPad.** El proyecto declara iPhone y iPad. No se verificó qué iPads no pueden ir a iPadOS 26. ¿Se usa la app en iPad?
5. **Lista de dispositivos de Apple.** La lista (iPhone XS, XS Max y XR) viene de Wikipedia, que cita a Apple. No se pudo leer la página oficial de compatibilidad de iOS 26. Confirmarla en apple.com antes de comunicar a los testers.
6. **Versión de Xcode.** En esta máquina `xcodebuild -version` devuelve Xcode 27.0 (27A266a); el usuario indica 27.2.1. ¿Cuál se usa para compilar y firmar?
7. **Cifrado.** Hoy el audio UDP va en claro y Multipeer con cifrado opcional. ¿Se quiere cifrar? Cambia el diseño del transporte y el costo de batería (pregunta 13 del estudio).
8. **Tamaño del grupo.** El tope es 5 vecinos por nodo (grupo de 6 a la vista). ¿Cuántos riders reales son el objetivo? (pregunta 7 del estudio).
9. **Segundo plano.** Si la prueba del spec 2 muestra que Multipeer o Network no sobreviven en segundo plano con el modo `audio`, ¿se autoriza evaluar el modo `voip` (con CallKit y revisión de Apple) o se prefiere avisar al rider?
10. **Bitrate adaptativo.** Se fijó 24 kbps; el adaptativo queda en backlog (pregunta 17 del estudio). ¿Se necesita?
11. **Aprobación por fase.** ¿Qué prueba aprueba cada fase antes de TestFlight (por ejemplo, una ruta en moto real)? Los specs exigen la prueba en dispositivo; falta fijar quién firma.
12. **Autenticación de la malla.** Las listas de vecinos del spec 4 no están autenticadas; un nodo con mala intención podría mentir. Riesgo aceptado mientras no haya cifrado.
13. **Caso de Daniela (informe de campo, no cubierto por los specs).** En la prueba de ayer entre el usuario y Daniela, ella oía al usuario y el usuario a ella, pero el mensaje indica que "ella no se oía nada"; ella está en el grupo de externos. No quedó claro qué dispositivo usa Daniela, cuál es el grupo "externos" (¿Android por Universal?) ni qué se oyó exactamente. No se diagnosticó ni se asumió causa. Candidatos que los specs ya contemplan sin afirmarlos: formato de malla distinto entre nodos (estudio, riesgo 1), Opus apagado frente a encendido (comentario del código), y el puente Auto que reenvía sin TTL. Hace falta: modelo y versión de cada dispositivo, modos de transporte y de malla en cada uno, y el log de ambos.

## Cómo está verificado cada dato

- Código: archivo y línea del estudio, más lectura directa de `project.yml`, `Info.plist`, `AudioTransport.swift` y `MeshRelay.swift` al escribir los specs.
- API de iOS 26: nombres y disponibilidad leídos en el SDK local de Xcode (`Network.swiftinterface`, `MCSession.h`). Las firmas exactas de `NetworkBrowser` para Bonjour y la entrega de datagramas por `NetworkListener` quedan por confirmar en el prototipo (spec 5, tarea 1).
- Fuentes web: las citadas en cada spec y en el estudio. Lo que no se pudo abrir está dicho.
