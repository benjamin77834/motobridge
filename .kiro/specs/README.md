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
| 7 | `audio-encryption` | Cifrado de la voz en capa de aplicación, capacidad `ENC` negociada, degradación a claro solo en la transición | 1, 3, 4 (no depende del 5; el 2 no es requisito) |

El spec 7 se aplica a la carga del formato de voz v2 (spec 3) y los relays del spec 4 reenvían la trama cifrada sin descifrarla; por eso va después de 1, 3 y 4. Dos de sus decisiones (gestión de la clave del grupo y revocación) están abiertas y requieren al usuario antes de la implementación (`audio-encryption/design.md`). Los specs 2 y 3 son independientes entre sí en lo técnico. El spec 6 es el de menor riesgo y se puede publicar primero. Cada spec trae tareas para iOS, Android y Mac Relay.

## Respuestas del usuario a las preguntas abiertas (segunda ronda)

Numeradas como en la respuesta del usuario (no coinciden con la numeración de la lista anterior de preguntas). Los specs las citan como "README, respuesta N". Prevalecen sobre cualquier supuesto previo.

| N | Respuesta | Dónde se aplicó |
|---|---|---|
| 1 | Xcode de referencia: 27.2.1. En la máquina donde se escribieron los specs `xcodebuild -version` informa Xcode 27.0 (27A266a); se anota la diferencia y no bloquea. | Spec 5, A2 y tarea 1.1 |
| 2 | Mantener la compatibilidad (C1 a C4) con versiones anteriores durante la transición. | Spec 1 (R8), todos los specs, sección C1 a C4 |
| 3 | Mac Relay sube a macOS 26. Aceptado. | Spec 5, requirements |
| 4 | Sí se usa iPad; se acepta que los modelos sin iPadOS 26 queden fuera. Verificado contra Apple: ver "Dispositivos" abajo. | Spec 5, requirements; spec 1, R8.4 |
| 5 | Metas aceptadas: voz boca a oído ≤ 250 ms con 1 salto y ≤ 400 ms con 3 saltos; rejoin p90 ≤ 8 s. Siguen sin medirse. | Specs 2, 3 y 5 |
| 6 | La app debe estar siempre activa mientras haya enlace. Se autoriza evaluar el modo `voip` con CallKit si el modo `audio` no basta, sabiendo que Apple rechazó antes un build por un crash al arrancar con `voip` y `location` (ya quitados) y que hay riesgo de revisión. La decisión se toma con la evidencia de la prueba en dispositivo. | Spec 2, design (alternativas) y tarea 6.4 y 6.5 |
| 7 | Cifrar el audio: sí. Nuevo spec `audio-encryption`, sin romper compatibilidad. | Spec 7; specs 1, 3, 5 apuntan a él |
| 8 | Tamaño de grupo, decisión delegada al arquitecto: objetivo de 6 riders por vista directa (límite de 5 conexiones por nodo) y más por malla multi-salto con TTL 6. No se sube el límite de 5. El número real de riders soportados queda por medir. | Spec 4, design, decisión 6 |

### Dispositivos (respuesta 4)

- iPhone: los avisos de seguridad de Apple de iOS 26.2 y 26.3 listan el destino como "iPhone 11 and later" ([Apple, iOS 26.3 y iPadOS 26.3](https://support.apple.com/en-gw/126346)). Eso respalda que el iPhone XS, XS Max y XR quedan fuera. La página de compatibilidad de iOS 26 en apple.com no se pudo leer de forma automática (la dirección probada devolvió 404 y la de soporte rechazó la consulta con 429), así que la lista completa sigue por confirmar a mano.
- iPad: el mismo aviso lista iPad Pro 12,9 pulgadas de 3.ª generación y posteriores, iPad Pro 11 pulgadas de 1.ª y posteriores, iPad Air de 3.ª y posteriores, iPad de 8.ª y posteriores, e iPad mini de 5.ª y posteriores. Quedan fuera los iPad anteriores a esos modelos. Un hilo de la comunidad de Apple dice que el iPad de 7.ª generación no es compatible con iPadOS 26 (fuente no oficial; coincide con el corte de la 8.ª generación del aviso).
- Cuando se retire la compatibilidad (spec 1, R8), los dispositivos sin iOS 26 o iPadOS 26 quedan en la última build compatible y no entran a grupos nuevos.

## Decisiones del usuario aplicadas (primera ronda)

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

**Cuándo se retiran:** cuando (a) todos los testers del grupo confirmen una build con protocolo 2 o mayor, (b) el contador local de peers legacy marque 0 durante 14 días seguidos y (c) el usuario lo apruebe por escrito (spec 1, R8.2). Hasta entonces el código legacy queda en rutas `Legacy*` para borrarlo de una vez. Los iPhone XS, XS Max y XR y los iPad sin iPadOS 26 quedan fuera de los grupos nuevos cuando eso ocurra.

## Retiro de Multipeer (no está en estos specs)

Se retira en un spec futuro cuando se cumplan: la matriz de segundo plano muestra que Network cubre lo que cubría Multipeer; dos builds de TestFlight seguidas sin regresión del camino Network; ya no hay iPhone con iOS < 26 en el grupo; y el usuario lo aprueba por escrito. Multipeer está deprecado en el SDK de Xcode 27 (`API_DEPRECATED ... ios(7.0, 27.0)`), pero hoy es una advertencia de compilación y no se encontró fecha de eliminación.

## Revisión del TTL

El TTL se queda en 6. Los contadores del spec 4 (R8) alimentan una revisión tras la primera prueba de campo con al menos 4 dispositivos. Fecha de revisión: por fijar al terminar esa prueba.

## Preguntas cerradas (no se repiten)

De la lista anterior de preguntas se cerraron: latencia y rejoin (respuesta 5), macOS 26 (3), iPad (4), versión de Xcode (1), cifrado (7), tamaño del grupo (8) y segundo plano/`voip` (6, la decisión final queda sujeta a la prueba). La pregunta de la lista oficial de dispositivos quedó parcial: ver "Dispositivos".

## Preguntas abiertas (no se inventó ningún dato)

1. **Build baseline.** ¿Qué commit o build de TestFlight es "la última publicada"? Se propuso `f494455` por ser el HEAD de cuando se escribieron los specs. Cambia la matriz C1.
2. **Lista oficial de dispositivos.** Confirmar en apple.com las páginas de compatibilidad de iOS 26 y iPadOS 26 antes de comunicarlas a los testers (ver "Dispositivos").
3. **Bitrate adaptativo.** Se fijó 24 kbps; el adaptativo queda en backlog (pregunta 17 del estudio). ¿Se necesita?
4. **Aprobación por fase.** ¿Qué prueba aprueba cada fase antes de TestFlight (por ejemplo, una ruta en moto real)? Los specs exigen la prueba en dispositivo; falta fijar quién firma.
5. **Autenticación de la malla.** Las listas de vecinos del spec 4 no están autenticadas; un nodo con mala intención podría mentir. El spec 7 cifra la voz pero no resuelve esto; sigue como riesgo aceptado.
6. **Decisiones abiertas del spec 7 `audio-encryption`** (detalle en su `design.md`): D1 algoritmo AEAD, D2 cómo se crea y comparte la clave del grupo, D3 nonce, D4 revocación al sacar a un rider, D5 si se cifran presencia y metadatos, D6 presupuesto de batería y D7 cuándo `obligatorio` pasa a ser el valor por defecto. D2, D4 y D5 necesitan al usuario.
7. **Resultado de la prueba de segundo plano y decisión sobre `voip`.** Depende de la prueba del spec 2 (tarea 6) y no se puede decidir antes. Si se evalúa `voip`, queda por decidir si el riesgo de revisión de Apple es aceptable con la evidencia en la mano.
8. **Fecha de revisión del TTL y número real de riders.** Se fijan tras la primera prueba de campo con al menos 4 dispositivos (spec 4, R8).
9. **Caso de Daniela (informe de campo, no cubierto por los specs).** En la prueba de ayer entre el usuario y Daniela, ella oía al usuario y el usuario a ella, pero el mensaje indica que "ella no se oía nada"; ella está en el grupo de externos. No quedó claro qué dispositivo usa Daniela, cuál es el grupo "externos" (¿Android por Universal?) ni qué se oyó exactamente. El informe `.agents/tasks/daniela-one-way-audio.md` ordena hipótesis (lo más probable es el micrófono de Daniela cerrado o sin señal) y no puede confirmar ninguna sin datos. Hace falta: modelo y versión de cada dispositivo, modos de transporte y de malla en cada uno, y el log de ambos.

## Cómo está verificado cada dato

- Código: archivo y línea del estudio, más lectura directa de `project.yml`, `Info.plist`, `AudioTransport.swift` y `MeshRelay.swift` al escribir los specs.
- API de iOS 26: nombres y disponibilidad leídos en el SDK local de Xcode (`Network.swiftinterface`, `MCSession.h`). Las firmas exactas de `NetworkBrowser` para Bonjour y la entrega de datagramas por `NetworkListener` quedan por confirmar en el prototipo (spec 5, tarea 1).
- Fase 0 (esta revisión): los datos de dispositivos vienen de la página de soporte de Apple citada en "Dispositivos"; el cifrado no tiene datos medidos y sus decisiones abiertas están listadas. Registro de lo hecho en `.agents/tasks/mesh-phases/phase0-notes.md`.
- Fuentes web: las citadas en cada spec y en el estudio. Lo que no se pudo abrir está dicho.
