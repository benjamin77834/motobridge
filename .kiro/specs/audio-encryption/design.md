# Diseño: audio-encryption
## Visión general
El audio se cifra en la capa de aplicación, antes de la cabecera de malla. Así lo cubren por igual Multipeer, UDP/Bonjour y Network framework, y los relays de malla reenvían bytes opacos sin descifrar. La capacidad `ENC` se anuncia en la presencia (spec 1). Con cualquier par sin `ENC` el grupo entero baja a claro y lo indica en pantalla, igual que ya se decidió para Opus en el spec 3.
**Stack (bloqueado al aprobar):** Swift (CryptoKit) en iOS y Mac, Kotlin (`javax.crypto`) en Android. Sin librerías nuevas.
## Formato de la trama
```
[ cabecera de malla 9 B: originId | packetId | ttl ]   (sin cifrar; originId y packetId son datos asociados)
[ byte de códec: bit 7 = v2, bit 6 = cifrado ]         (sin cifrar)
[ secuencia v2, 2 B ]                                  (sin cifrar)
[ contador de cifrado ]                                (sin cifrar; tamaño por fijar en D3)
[ carga cifrada ]  [ etiqueta de autenticación ]
```
- El bit 6 del byte de códec es una propuesta. Los valores v2 del spec 3 son 0x80 y 0x81; con el bit 6 serían 0xC0 y 0xC1. La tarea 1 comprueba que ni la baseline ni el spec 3 usan ese bit.
- Datos asociados (AAD): `originId`, `packetId`, byte de códec. Excluye `ttl` porque cada relay lo modifica.
- Nonce: se deriva de `originId` y el contador de cifrado (D3). Un nonce nunca se reutiliza con la misma clave.
- El tamaño del contador y de la etiqueta no está fijado. Con Opus a 24 kbps la trama de 20 ms ocupa unos 60 bytes de carga (24 000 bit/s × 0,02 s ÷ 8); la sobrecarga de etiqueta y contador se medirá contra eso (R5.1). Es un cálculo, no una medición.
## Decisión 1: capa de aplicación, no cifrado del transporte
**Elegido:** AEAD sobre la carga de voz.
Alternativas descartadas:
- *Solo `encryptionPreference: .required` de Multipeer y TLS/DTLS en Network:* cifra cada salto, no extremo a extremo; el camino UDP de Android no lo tiene; cada transporte tendría una política distinta y los relays verían el audio en claro. Android no puede unirse a Multipeer ni a la red Wi-Fi peer-to-peer de Apple (spec 5, A5), así que no hay un solo mecanismo de transporte común.
- *QUIC con datagramas en Network:* ya descartado en el spec 5 por no existir en Android sin biblioteca nueva. Reconsiderar solo si D1 falla.
Un nodo de la malla es parte del grupo y tiene la clave; el cifrado extremo a extremo aquí significa "solo el grupo", no "ni siquiera los relays" (los relays son miembros).
## Decisión 2: negociación y degradación
- `ENC` en `CAP` indica "puedo cifrar y descifrar y tengo la clave del grupo". Un nodo sin clave o sin almacén seguro no lo anuncia.
- Función de selección única en el controlador, igual que la de códec del spec 3: cifrar solo si todos los vecinos directos y todos los orígenes vistos en 30 s declaran `ENC`.
- Cambio a claro en menos de 500 ms al conectar un vecino de capacidades desconocidas; regreso a cifrado tras 10 s sin nodos sin `ENC` (histéresis, para no oscilar).
- Política local `compatible` (por defecto en la transición) u `obligatorio`.
- Nunca se envía una trama cifrada a un vecino sin `ENC`, porque no se sabe cómo reaccionaría una app vieja (A3). La tarea 1 lo prueba; aunque resultara inocuo, la regla se mantiene.
- Un relay que recibe una trama cifrada y tiene un vecino sin `ENC` no se la reenvía a ese vecino, y cuenta `descartado por capacidad`. Por R3.2 el origen ya debió haber bajado a claro; esto es defensa.
Alternativa descartada: *cifrar solo hacia los vecinos con `ENC` y enviar claro a los demás a la vez.* Duplica el envío y el ancho de banda, y en malla un origen no sabe qué vecinos tienen los nodos lejanos.
## Decisión 3: algoritmo, nonce y orden
No se inventa nada. Se propone un AEAD estándar. **La elección final es la decisión abierta D1**, porque depende de qué ofrece cada plataforma (A2).
Candidatos:
| Candidato | Nota para decidir |
|---|---|
| AES-GCM | Disponible en CryptoKit y en `javax.crypto`. Si las tres plataformas lo soportan sin dependencias, es la opción más simple. El efecto en batería depende de la aceleración por hardware de cada chip; se mide (R5.2). |
| ChaCha20-Poly1305 | Disponible en CryptoKit. En Android depende del nivel de API del proveedor; con `minSdk` 26 hay que comprobarlo en la tarea 1 antes de proponerlo. |
**Recomendación del arquitecto, sujeta a la tarea 1:** AES-GCM de 128 bits o 256 bits si las tres plataformas lo exponen sin dependencias; ChaCha20-Poly1305 solo si Android lo soporta en todo `minSdk` y la medición de batería lo favorece. No se fija hasta tener las dos mediciones.
**Clave por emisor y nonce.** La clave del grupo no se usa directamente. Se deriva una clave por origen con una función de derivación estándar (HKDF) a partir de la clave del grupo, el `originId` y un identificador de sesión. El nonce se forma con un contador que crece por trama. Razón: `originId` es de 32 bits aleatorios por sesión (spec 1, R1.3) y dos emisores con el mismo `originId` y la misma clave usarían el mismo nonce; con clave por emisor y sesión eso deja de importar. La secuencia v2 de 16 bits se repite cada 65 536 tramas, unos 21,8 minutos de voz continua a 20 ms (65 536 × 0,02 s), así que no sirve como contador de nonce. Se necesita un contador propio más ancho (D3). El `originId` cambia en cada arranque (spec 1), lo que ya reinicia la sesión de clave.
**Anti-repetición.** El receptor mantiene por origen el contador más alto visto y una ventana de contadores recientes. Un contador ya visto o más viejo que la ventana se descarta. Esto convive con la deduplicación de malla (`originId` + `packetId`), que sigue siendo la primera barrera.
## Decisión 4: gestión de claves del grupo
**Esta es la parte con más decisiones abiertas y no se resuelve aquí.** Lo que se sabe: no hay hoy un concepto de grupo con secreto (A1, por verificar). Opciones, sin elegir:
| Opción | Qué implica | Riesgo |
|---|---|---|
| Código de grupo compartido en persona (texto o QR) del que se deriva la clave | Simple, sin servidor, sirve a Android, iOS y Mac. El código debe ser suficientemente aleatorio; un código corto o fácil de adivinar se puede atacar por fuerza bruta. | Un código débil o filtrado compromete al grupo. Revocar exige un código nuevo para todos. |
| El líder genera la clave y la entrega a cada miembro por un canal ya autenticado con el código | Permite rotar la clave sin que todos reescriban el código. | Necesita un intercambio de claves y un protocolo de entrega nuevo. Más superficie de error. No se diseña sin aprobación. |
| Intercambio de claves entre pares con confirmación visual | Evita el código compartido. | Complejo en malla multi-salto. Fuera de alcance salvo decisión expresa. |
Un diseño de gestión de claves se redacta cuando el usuario resuelva D2 y D4. Este spec solo fija lo que no depende de esa elección: la clave se guarda en el almacén seguro (R2.3), no se registra en logs (R2.2) y un nodo sin la clave nunca anuncia `ENC`.
## Decisión 5: costo de batería
El cifrado AEAD de unos 60 bytes cada 20 ms es una carga pequeña frente a Opus y a la radio, pero no se afirma un número sin medirlo. La tarea 8 mide la misma ruta de 30 min con y sin cifrado en un iPhone y un Android físicos. El relay no descifra, por lo que su costo extra es nulo (R5.4). El presupuesto aceptable lo fija el usuario con la medición en la mano (D6).
## Decisión 6: qué no se cifra y por qué
Presencia, `NB`/`HRD` y keepalives no se cifran: son los que permiten descubrir y medir al vecino antes de tener clave, y la presencia es la que anuncia `ENC`. Un observador puede ver nombres, quién está en el grupo, y el tamaño y la cadencia de las tramas. Se documenta en `KNOWN_LIMITATIONS.md` (R7.3). Cifrar metadatos es una decisión abierta (D5).
## Decisiones abiertas (requieren al usuario o una medición)
| # | Decisión | Qué la define |
|---|---|---|
| D1 | Algoritmo AEAD (AES-GCM o ChaCha20-Poly1305) y tamaño de clave | Tarea 1: soporte real en iOS 17 o 26, macOS y Android `minSdk` 26; medición de batería |
| D2 | Cómo se crea y comparte la clave del grupo (código, QR, líder) | El usuario, según cómo arman los grupos en la vida real |
| D3 | Tamaño del contador de nonce y cómo se garantiza que no se repite tras reiniciar | Diseño detallado tras D1 y D2; clave de sesión nueva por arranque lo evita en gran parte |
| D4 | Revocación y rotación al sacar a un rider | El usuario; depende de D2 |
| D5 | Si se cifran presencia, `NB`/`HRD` y nombres | El usuario; cuesta el descubrimiento y la compatibilidad con la baseline |
| D6 | Presupuesto aceptable de batería y CPU | La medición de la tarea 8 y el usuario |
| D7 | Cuándo `obligatorio` pasa a ser el valor por defecto | Retiro de la compatibilidad (spec 1, R8.2) y aprobación escrita |
## Archivos a modificar
- iOS: nuevo `MotoBridge/Core/Audio/AudioCrypto.swift` (lógica pura: derivación, cifrar, descifrar, ventana anti-repetición), `AudioIO.swift` y `NetworkBridgeController.swift` (selección de cifrado y envío), `MeshRelay.swift` (sin cambios en la cabecera; `originId` y `packetId` se pasan como AAD), `AudioDiagnosticsView.swift` (contadores e indicador), `PROTOCOL.md`, `KNOWN_LIMITATIONS.md`.
- Android: nuevo `audio/AudioCrypto.kt`, `AudioIO.kt`, `BridgeController.kt`, `net/MeshRelay.kt`.
- Mac: `RelayAudio.swift`, `RelaySession.swift`, `project.yml` (agregar `AudioCrypto.swift` a `sources`).
- La interfaz para crear y compartir la clave se diseña después de resolver D2.
## Manejo de errores
| Operación | Falla | Tipo | El llamador recibe | Log |
|---|---|---|---|---|
| Leer la clave del almacén seguro | No disponible | Recuperable | Nodo sin `ENC`; `compatible`: claro con aviso; `obligatorio`: silencio con motivo | `warning` |
| Descifrar una trama | Etiqueta inválida | Recuperable | Se descarta y se cuenta; si son muchas seguidas de un origen, aviso "clave distinta" | contador y `debug` |
| Descifrar una trama | Contador repetido o fuera de ventana | Recuperable | Se descarta y se cuenta | contador |
| Cifrar una trama | Excepción de la API | Recuperable | Esa trama se pierde; tras 3 seguidas el nodo baja a claro 30 s en `compatible` o silencia en `obligatorio` | `warning` |
| Par sin `ENC` aparece | Capacidades desconocidas | Recuperable | Grupo a claro y indicador "sin cifrar" | `info` |
| Trama cifrada llega a un nodo sin clave | Sin clave | Recuperable | Se descarta; aviso "clave distinta" | contador |
Ningún error es fatal para la app. El peor caso es audio en claro en modo `compatible`, es decir, la baseline.
## Validación de entradas externas
| Entrada | Obligatoria | Tipo y límite | Si falla |
|---|---|---|---|
| Byte de códec | Sí | Valores definidos en spec 3 más los cifrados | Descartar |
| Longitud de la trama cifrada | Sí | Mayor que contador más etiqueta y no mayor que el máximo del spec 3 más la sobrecarga | Descartar |
| Contador | Sí | Entero sin signo del ancho fijado en D3 | Descartar |
| Etiqueta | Sí | Longitud exacta del algoritmo | Descartar |
## Estrategia de pruebas
- Vectores compartidos de cifrado en iOS, Android y Mac (R7.1).
- Unitarias de la ventana anti-repetición y de la selección de cifrado con tabla de capacidades simulada.
- Interoperabilidad: matriz C1 en modo `compatible` contra la baseline; una cadena de 3 nodos con un relay que no descifra.
- Batería y CPU: tarea 8.
