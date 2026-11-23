# Requisitos: audio-encryption
## Objetivo
Cifrar la voz de extremo a extremo dentro del grupo, en todos los caminos de red (Multipeer, UDP/Bonjour y, más adelante, Network framework de iOS 26), sin romper a las builds anteriores. El cifrado es una capacidad negociada por par. Con pares viejos el audio baja a claro solo durante la transición, y el rider lo ve en pantalla. Cuando se retire la compatibilidad (spec 1, R8), el cifrado pasa a ser obligatorio.
## Dependencias
- Spec 1 `protocol-capabilities-baseline` (token `ENC` en `CAP`, tabla de capacidades por vecino y por origen, id de vecino en recepción, contador legacy).
- Spec 3 `voice-pipeline-opus-jitter` (formato de audio v2 con secuencia; el cifrado se aplica a la carga de ese formato).
- Spec 4 `mesh-smart-relay` (los relays reenvían el paquete sin descifrarlo; la cabecera de malla no se cifra).
- Spec 5 no es requisito. El cifrado vive en la capa de aplicación y es independiente del transporte. Si el spec 5 se hace antes, el camino Network hereda el cifrado sin cambios.
## Origen y supuestos
- Entrada: decisión del usuario 7 del README ("sí, ya es momento"), estudio pregunta 13, NF3 del spec 1 y R9.1 del spec 5 (que dejaron el cifrado fuera hasta ahora).
- Hecho del código: el audio UDP (iOS, Android, Mac) viaja en claro. Multipeer usa `encryptionPreference: .optional` (`PeerBridgeSession.swift:148`, `RelaySession.swift:229`). Una búsqueda en `MotoBridge/`, `MonoBridgeRelay/` y `android/app/src` no encontró uso de CryptoKit, `Cipher` ni `javax.crypto`: hoy no hay cifrado propio.
- Hecho del código: la cabecera de malla mide 9 bytes (`originId` 4, `packetId` 4, `ttl` 1; `MeshRelay.swift:4-8`). El `ttl` cambia en cada salto.
- Hecho del código: el relay reenvía lo que recibió sin transcodificar (spec 3). Un relay no necesita descifrar.
- Supuesto A1: no existe hoy un "grupo" con secreto compartido; los riders se encuentran por Bonjour o Multipeer sin autenticación. Se verifica en la tarea 1. Por eso la gestión de claves (R2) es una decisión abierta (ver `design.md`, "Decisiones abiertas") y este spec no la da por resuelta.
- Supuesto A2: Android y Mac pueden hacer el mismo AEAD que iOS con APIs de plataforma, sin dependencias nuevas. **No verificado.** La tarea 1 lo comprueba antes de fijar el algoritmo (ver decisión abierta D1).
- Supuesto A3: una app vieja que recibe un byte de códec desconocido puede reproducirlo como ruido o fallar. **No verificado.** La tarea 1 lo prueba; hasta entonces el diseño no envía nunca tramas cifradas a un vecino sin `ENC` (R3).
- Los criterios de compatibilidad C1 a C4 del README rigen durante la transición.
## Requisitos funcionales (EARS)
### R1. Cifrado de la carga de voz
CUANDO un nodo con `ENC` envía una trama de voz a un grupo cuyos nodos conocidos declaran todos `ENC` y comparten clave, EL SISTEMA DEBERÁ cifrar y autenticar la carga de audio con un cifrado AEAD antes de envolverla en la cabecera de malla.
Criterios de aceptación:
1. R1.1 La trama cifrada lleva un identificador de cifrado en el byte de códec (bit definido en `design.md`) y no es interpretable como PCM u Opus por un receptor sin `ENC`.
2. R1.2 La cabecera de malla no se cifra. `originId` y `packetId` se autentican como datos asociados; `ttl` no, porque cambia en cada salto.
3. R1.3 Un relay reenvía la trama cifrada sin descifrarla y sin cambiar su contenido más allá del `ttl`.
4. R1.4 Una trama con etiqueta de autenticación inválida se descarta, se cuenta y no produce sonido.
5. R1.5 Una trama cifrada repetida (mismo origen y contador) se descarta aunque la etiqueta sea válida (anti-repetición).
6. R1.6 El nonce no se repite nunca con la misma clave y el mismo origen, incluso tras reiniciar la app (prueba con contador persistente o con clave de sesión nueva; ver D3).
### R2. Clave del grupo
EL SISTEMA DEBERÁ permitir que los riders de un grupo compartan una clave, y DEBERÁ impedir que un nodo sin esa clave descifre la voz.
Criterios de aceptación:
1. R2.1 El rider crea o ingresa la clave del grupo con un gesto que el spec fija después de resolver D2 (por ejemplo código o QR). Hasta que D2 esté decidida, este criterio no se implementa.
2. R2.2 La clave no se envía por la red en claro ni se escribe en logs ni en el diagnóstico exportado.
3. R2.3 La clave se guarda en el almacén seguro del sistema (Keychain en iOS y Mac; almacén de claves de Android), no en `UserDefaults` ni en preferencias en claro.
4. R2.4 Un nodo con clave distinta recibe tramas que fallan la autenticación (R1.4) y el rider ve el aviso "clave distinta" en vez de silencio.
5. R2.5 Quitar a un rider del grupo requiere cambiar la clave (D4). Hasta que D4 esté decidida, la baja de un miembro no revoca su acceso y la documentación lo dice.
### R3. Negociación y degradación por par
MIENTRAS un vecino directo o un origen conocido no declare `ENC`, EL SISTEMA DEBERÁ enviar audio en claro con el formato que ese par entiende y DEBERÁ mostrar al rider que el grupo no está cifrado.
Criterios de aceptación:
1. R3.1 Nunca se envía una trama cifrada a un vecino sin `ENC`. Un vecino de capacidades desconocidas cuenta como sin `ENC` (R4.1 del spec 1).
2. R3.2 Con un par sin `ENC` en el grupo, todo el grupo cambia a claro en menos de 500 ms tras conectarlo (misma regla que Opus en el spec 3) y se muestra el indicador "sin cifrar".
3. R3.3 Cuando el último nodo sin `ENC` sale del grupo y pasan 10 s, el grupo vuelve a cifrado y el indicador pasa a "cifrado".
4. R3.4 El indicador distingue tres estados: cifrado, sin cifrar por compatibilidad y clave distinta.
5. R3.5 La política es una opción local con dos valores: `compatible` (R3.1 a R3.3) y `obligatorio` (no se envía ni se reproduce audio en claro). `compatible` es el valor por defecto durante la transición. El cambio de valor por defecto a `obligatorio` ocurre solo al retirar la compatibilidad (spec 1, R8.2) y con aprobación escrita del usuario.
6. R3.6 En modo `obligatorio` un par sin `ENC` no se oye y el rider ve el motivo.
### R4. Compatibilidad con builds anteriores
EL SISTEMA DEBERÁ mantener C1 a C4 con builds sin `ENC`.
Criterios de aceptación:
1. R4.1 La nueva build y la baseline (o la última de TestFlight) se oyen en iOS↔iOS, iOS↔Android, iOS↔Mac y Android↔Android en modo `compatible`.
2. R4.2 Con malla encendida, una cadena origen `ENC` → relay `ENC` → nodo baseline no entrega ruido al nodo baseline (C3). Si el origen cifra, el nodo baseline queda fuera de ese flujo y por R3.2 el grupo ya habría bajado a claro.
3. R4.3 Un nodo baseline en el grupo sigue oyendo y siendo oído (spec 1, R7).
4. R4.4 Presencia, listas de vecinos (`NB`, `HRD`), keepalives y nombres no se cifran en este spec (ver D5). El payload de presencia solo añade el token `ENC` en `CAP`.
### R5. Costo de batería y CPU
EL SISTEMA DEBERÁ medir el costo del cifrado y mantenerlo dentro de un presupuesto verificable.
Criterios de aceptación:
1. R5.1 El tamaño añadido por trama (contador, etiqueta) queda documentado y medido. Con Opus a 24 kbps, la sobrecarga por trama se compara con el tamaño de la trama de 20 ms.
2. R5.2 La prueba compara la misma ruta de 30 min con cifrado y sin cifrado en un iPhone físico y un Android físico, midiendo CPU y porcentaje de batería consumido. El presupuesto lo fija el usuario después de ver la medición (D6); no se propone un número antes de medir.
3. R5.3 El cifrado y descifrado ocurren fuera del hilo de captura y de reproducción de audio y no aumentan la latencia boca a oído en más de 5 ms con 1 salto (meta propuesta, por confirmar).
4. R5.4 El relay no gasta CPU en descifrar. Una prueba con 3 nodos verifica que el nodo intermedio no invoca el descifrado.
### R6. Errores y fallo seguro
Criterios de aceptación:
1. R6.1 Ningún error de cifrado hace crash. Una trama que no se puede procesar se descarta y se cuenta.
2. R6.2 Si el almacén seguro no está disponible o la clave no se puede leer, el nodo pasa a `compatible` sin cifrar, anuncia que no tiene `ENC` y muestra el aviso; no cifra con una clave vacía.
3. R6.3 En modo `obligatorio`, el mismo fallo silencia el audio y muestra el motivo en vez de bajar a claro.
### R7. Prueba y documentación
Criterios de aceptación:
1. R7.1 Vectores de prueba compartidos (clave, nonce, datos asociados, texto plano, texto cifrado) que iOS, Android y Mac cifran y descifran de forma idéntica.
2. R7.2 `PROTOCOL.md` documenta el formato cifrado, el byte de códec, el nonce, los datos asociados, la negociación y la política.
3. R7.3 `KNOWN_LIMITATIONS.md` registra lo que el cifrado no cubre: metadatos (nombres, listas de vecinos, tamaño y cadencia de tramas), un miembro con la clave que se queda en el grupo y la revocación pendiente (D4).
4. R7.4 La matriz C1 se ejecuta con la build nueva en modo `compatible` antes de publicar en TestFlight.
## Requisitos no funcionales
- NF1. Sin dependencias de terceros nuevas. Solo APIs de plataforma (CryptoKit en iOS y Mac, `javax.crypto`/proveedor de Android). Si una plataforma no puede, se vuelve a la decisión D1 antes de seguir.
- NF2. Ningún algoritmo ni protocolo criptográfico inventado: solo un AEAD estándar y una derivación de claves estándar.
- NF3. La clave y el texto plano de audio no salen del dispositivo salvo cifrados por la red de voz.
## Fuera de alcance
- Cifrado de presencia, `NB`/`HRD`, keepalives y metadatos (D5).
- Autenticación de nodos de la malla frente a un nodo que miente en sus listas de vecinos (queda como riesgo; el cifrado no lo resuelve).
- Cifrado del transporte (TLS, DTLS, `encryptionPreference` de Multipeer). Se conservan los valores del spec 5, R9.1. El cifrado de aplicación cubre los tres caminos por igual.
- Revocación automática de miembros (D4).
- Malla de Android más allá de lo que ya cubren los specs 3 y 4.
- TestFlight y publicación.
