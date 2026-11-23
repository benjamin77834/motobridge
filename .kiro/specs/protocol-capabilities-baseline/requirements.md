# Requisitos: protocol-capabilities-baseline

## Objetivo

Hacer evolucionable el protocolo de red de Mono Bridge sin romper a nadie durante la transición: anunciar versión y capacidades por par, identificar quién envía cada paquete, degradar al formato actual cuando un par no soporta algo, y dejar `PROTOCOL.md` alineado con el código. No cambia el formato de audio ni de malla.

## Dependencias

Ninguna. Es el spec 1 y los specs 2 a 5 dependen de él.

## Origen y supuestos

- Entrada: `.agents/tasks/ios-mesh-network-framework-study.md` (§2 filas de protocolo/presencia, §3 riesgo 1, §5 spec 1).
- Decisión del usuario 2: las versiones nuevas pueden obligar a actualizar a todos. Por eso el criterio de compatibilidad C1 a C4 es **transitorio**: rige solo durante el rollout por TestFlight y se retira según R8.
- Supuesto A1: el parser de presencia de Android y de Mac ignora líneas desconocidas, como el de iOS (`NetworkBridgeController.swift:802-816`). **No está verificado**; R2 lo convierte en prueba y la tarea 1 lo comprueba antes de implementar nada.
- Supuesto A2: el tráfico de presencia sigue a 2 s en este spec.

## Criterios de compatibilidad (transitorios)

- C1. La versión nueva y la última build publicada o de TestFlight conectan y se oyen en grupo en iOS↔iOS, iOS↔Android, iOS↔Mac y Android↔Android.
- C2. Todo cambio de formato de red se anuncia por capacidad y se degrada al formato actual si el par no lo soporta.
- C3. Ningún cambio de red usa un tipo de canal nuevo sin comprobar antes que las apps viejas no lo reproducen como audio (clic).
- C4. Cada spec trae tareas para iOS, Android y Mac, o declara por qué una plataforma no aplica.

## Requisitos funcionales (EARS)

### R1. Anuncio de versión, identidad y capacidades

CUANDO un nodo emite presencia, EL SISTEMA DEBERÁ añadir tres líneas después del nombre: `PV=<entero>`, `ID=<8 hex>` y `CAP=<lista separada por comas>`, sin modificar la primera línea (nombre).

Criterios de aceptación:
1. R1.1 La primera línea del payload de presencia es idéntica byte a byte a la de la build baseline para el mismo nombre.
2. R1.2 `PV` es 2 en la primera build con este spec. Un nodo sin línea `PV` se trata como protocolo 1 (legacy).
3. R1.3 `ID` es el `originId` de malla del nodo (aleatorio por sesión, 32 bits) en hexadecimal de 8 caracteres en mayúsculas. Un reinicio de la app genera un `ID` nuevo.
4. R1.4 `CAP` solo contiene tokens definidos en `design.md`. Un token desconocido no invalida el resto de la línea.
5. R1.5 El payload de presencia completo no supera 200 bytes con todos los campos (nombre de 24 caracteres, ALT, BAT, PV, ID, CAP).

### R2. Tolerancia a campos desconocidos

CUANDO un nodo recibe una presencia con líneas que no conoce, EL SISTEMA DEBERÁ ignorarlas sin error y seguir mostrando al rider con su nombre.

Criterios de aceptación:
1. R2.1 Prueba automática en iOS, Android y Mac (la de Mac puede ejecutarse sobre la lógica compartida): una presencia con las líneas `PV=9`, `ID=ZZZZZZZZ`, `CAP=XYZ,HB` y `FOO=1` produce el mismo nombre de rider y no lanza excepción.
2. R2.2 Una presencia con líneas en blanco, líneas sin `=` o texto no UTF-8 en líneas posteriores a la primera no impide mostrar al rider cuando el nombre es válido.
3. R2.3 Una presencia de más de 512 bytes se descarta sin error y queda contada en el diagnóstico local.

### R3. Identificación del emisor en recepción

CUANDO el transporte entrega un paquete de audio o control, EL SISTEMA DEBERÁ entregar también el identificador del vecino directo por el que llegó (el `TransportPeer.id` de ese transporte).

Criterios de aceptación:
1. R3.1 En iOS (Multipeer y UDP), Android y Mac, el callback de recepción incluye el id del vecino directo.
2. R3.2 Una prueba con transporte simulado verifica que dos vecinos distintos producen ids distintos y que el mismo vecino produce siempre el mismo id.
3. R3.3 El comportamiento de audio con la malla apagada y con la malla encendida es idéntico al de la baseline (prueba de regresión).

### R4. Tabla de capacidades por vecino y por origen

EL SISTEMA DEBERÁ mantener una tabla en memoria con la versión y capacidades de cada vecino directo (clave: id de vecino del transporte) y de cada origen conocido (clave: `ID`), y DEBERÁ responder "¿todos los vecinos directos soportan X?" y "¿este vecino soporta X?".

Criterios de aceptación:
1. R4.1 Mientras no haya recibido presencia con `PV` de un vecino, la tabla lo reporta como protocolo 1 sin capacidades.
2. R4.2 Cuando llega una presencia con `CAP`, la tabla se actualiza en menos de 100 ms y la consulta refleja el cambio.
3. R4.3 Cuando un vecino directo se desconecta, su entrada se elimina en la misma pasada que se actualiza la lista de peers conectados.
4. R4.4 Una entrada de origen no vista durante 30 s se elimina.
5. R4.5 Si un mismo `ID` aparece con capacidades distintas, gana la presencia más reciente.
6. R4.6 La tabla soporta al menos 32 orígenes y 5 vecinos directos sin crecer más allá de eso (límite verificable por prueba).

### R5. Degradación por par

SI un vecino directo no declara una capacidad, ENTONCES EL SISTEMA DEBERÁ usar con ese vecino el comportamiento de la baseline para esa función y seguir usando el nuevo con los vecinos que sí la declaran.

Criterios de aceptación:
1. R5.1 Prueba de interoperabilidad: un nodo nuevo con un vecino legacy y otro nuevo mantiene audio bidireccional con ambos (C1).
2. R5.2 Este spec no introduce ninguna capacidad activa. R5.1 se verifica con una capacidad de prueba (`TEST`) que solo existe en builds de depuración.

### R6. Documentación alineada con el código

EL SISTEMA DEBERÁ tener `PROTOCOL.md`, `KNOWN_LIMITATIONS.md` y los comentarios del código sin las discrepancias que listó el estudio.

Criterios de aceptación:
1. R6.1 `PROTOCOL.md` documenta: audio PCM/Opus a 16 kHz con byte de códec (0x00 PCM, 0x01 Opus), cabecera de malla de 9 bytes, tipos de canal 0 a 7, servicio `_motobridge._udp`, líneas de presencia (`ALT`, `BAT`, `PV`, `ID`, `CAP`) y las tolerancias reales de liveness (30 s en Android y Mac, 7 s en radar iOS).
2. R6.2 `PROTOCOL.md` ya no dice PCM 8 kHz ni 5 s de poda.
3. R6.3 Los comentarios de `PeerBridgeSession.swift:15`, `PeerBridgeSession.swift:256` y `AudioTransport.swift:30` ya no afirman que Multipeer usa Bluetooth ni que el envío es `.reliable`. Ningún cambio de comportamiento (el diff solo toca comentarios).
4. R6.4 `KNOWN_LIMITATIONS.md` registra: RSSI por peer no disponible en iOS, Multipeer deprecado en Xcode 27, comportamiento en background no confirmado.

### R7. Matriz de interoperabilidad

EL SISTEMA DEBERÁ tener una matriz de pruebas de interoperabilidad ejecutable a mano contra la build baseline.

Criterios de aceptación:
1. R7.1 La matriz cubre las cuatro combinaciones de C1 y se registra el resultado (pasa o falla, fecha, build) por cada una.
2. R7.2 La build baseline se identifica por el commit `f494455` o por el commit que el usuario designe como publicado (ver pregunta abierta en README).
3. R7.3 Una combinación que falla bloquea la publicación en TestFlight de ese spec.

### R8. Ventana de transición y retiro de la compatibilidad

EL SISTEMA DEBERÁ documentar cuándo se puede retirar el código de compatibilidad con peers legacy, y DEBERÁ contar localmente cuántos peers legacy ve.

Criterios de aceptación:
1. R8.1 El diagnóstico local (pantalla de diagnóstico existente en iOS, log en Android y Mac) muestra el número de peers legacy vistos en los últimos 14 días. No se envía a ningún servidor.
2. R8.2 `PROTOCOL.md` define el retiro: se puede retirar la compatibilidad cuando se cumplan las tres condiciones: (a) todos los testers del grupo confirman estar en una build con `PV` igual o mayor a 2; (b) el contador de R8.1 marca 0 durante 14 días seguidos; (c) el usuario lo aprueba por escrito.
3. R8.3 El código de compatibilidad (rutas "legacy") queda aislado en funciones o clases con nombre `Legacy*` para poder borrarlo en un solo cambio.
4. R8.4 `PROTOCOL.md` y el README de specs advierten que iPhone XS, XS Max y XR (ver spec 5) se quedan en la última build compatible y dejan de poder unirse a grupos cuando se retire la compatibilidad.

## Requisitos no funcionales

- NF1. El tamaño agregado de las tres líneas nuevas no supera 80 bytes por presencia.
- NF2. Sin dependencias nuevas en iOS y Mac. En Android solo se añade JUnit como dependencia de pruebas (ver tarea 1).
- NF3. Sin cifrado nuevo. La seguridad queda fuera de alcance (ver README, pregunta abierta de cifrado).

## Fuera de alcance

- Cualquier cambio de formato de audio, de cabecera de malla, de TTL o de heartbeat (specs 2 a 4).
- Cifrado del audio.
- Versionado del servicio Bonjour.
