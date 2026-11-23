# Requisitos: mesh-smart-relay

## Objetivo

Reemplazar la inundación de la malla por un relay selectivo: un nodo reenvía un paquete de voz solo a los vecinos que no lo oyeron todavía y solo si él es el mejor siguiente salto, usando la calidad del enlace que mide la propia app. Aplica a iOS, Android y Mac Relay, y a los tres escenarios de topología del usuario: caravana lineal, grupos a la vista del líder y hotspot compartido.

## Dependencias

- Spec 1 (capacidades, tabla por vecino y por origen).
- Spec 2 (liveness y keepalive: de ahí sale la calidad de enlace; `SR` exige `HB`).
- Spec 3 (cabecera de malla siempre presente con pares `SEQ`: deduplicación por `originId` + `packetId` en todos los caminos).

## Origen y supuestos

- Entrada: estudio §2 sección A, riesgo 1, spec 4; decisiones del usuario 5, 6 y 8.
- Decisión 5 del arquitecto: el TTL máximo **se queda en 6** (no se baja a 3). Razón: el comentario del código y el caso de uso son caravanas de hasta 6 motos (`MeshRelay.swift:18`); bajar a 3 corta el alcance de los últimos y cambia el cálculo de saltos `hops = defaultTTL - ttl` (`MeshRelay.swift:51`, Android `MeshRelay.kt:42`) en las builds viejas. El relay selectivo, no el TTL, reduce la inundación. El TTL se revisa con datos de campo (R8).
- Decisión 8: iOS no expone RSSI por peer (foro de Apple 721067). La métrica del siguiente salto es calidad medida por la app (pérdida y estabilidad de los keepalives) y los saltos que se deducen de las listas de vecinos anunciadas; no hay RSSI.
- Hecho del código: hoy el relay reenvía a todos los peers conectados, incluido el que lo envió (`NetworkBridgeController.swift:1081-1083`); la condición de relé difiere (iOS: más de 1 peer; Android: nombre del peer con coma, `BridgeController.kt:396-399`); en modo gateway el puente reenvía el paquete original sin bajar el TTL (`NetworkBridgeController.swift:1088,1148-1150`).
- Hecho del código: el tope de conexiones es 5 por nodo (`PeerBridgeSession.swift:53`, `LocalNetworkTransport.swift`), así que un grupo "a la vista del líder" tiene un máximo de 6 riders; más allá, hace falta cadena.
- Supuesto A1: el aviso de vecinos viaja en la presencia de 2 s, no en el keepalive de 500 ms.
- Supuesto A2: no hay autenticación; un nodo malicioso puede mentir en su lista de vecinos. Se declara como riesgo, no se resuelve aquí.

## Requisitos funcionales (EARS)

### R1. Lista de vecinos y calidad en la presencia

CUANDO un nodo con `SR` emite presencia, EL SISTEMA DEBERÁ incluir una línea `NB=` con hasta 5 vecinos directos vivos en la forma `<ID de 8 hex>:<q de 0 a 9>` separados por coma, y una línea `HRD=` con hasta 4 orígenes oídos directamente en los últimos 2 s.

Criterios de aceptación:
1. R1.1 La primera línea de la presencia no cambia y las líneas `NB` y `HRD` son ignoradas por parsers legacy (prueba de los vectores del spec 1).
2. R1.2 `q` es la calidad con la que este nodo recibe a ese vecino, y se calcula como: `9 × (1 − pérdida)` redondeado, donde `pérdida` es la fracción de keepalives esperados que no llegaron en los últimos 4 s (8 esperados), menos 3 si el vecino está `inestable`, con piso 0.
3. R1.3 El payload de presencia completo no supera 256 bytes con todos los campos.
4. R1.4 Un vecino caído (spec 2) no aparece en `NB`.

### R2. Mejor siguiente salto

CUANDO un nodo R recibe por un vecino S un paquete nuevo del origen O con TTL mayor que 1, EL SISTEMA DEBERÁ reenviarlo únicamente a cada vecino directo vivo N con `SR` tal que: N no es S ni O; N no es vecino de S ni de O según las listas `NB` vigentes; y R es el mejor candidato para llegar a N.

Criterios de aceptación:
1. R2.1 Los candidatos para N son los nodos que tienen a N como vecino y que recibieron el paquete (vecinos de S, S mismo, y vecinos de O). R es el mejor si su `q` hacia N (anunciada por N en `NB`) es la mayor; el empate se resuelve con el `ID` menor.
2. R2.2 R conserva su elección de reenviar a N salvo que otro candidato supere su `q` por 2 o más (histéresis).
3. R2.3 Si la lista `NB` de S, O o N falta o tiene más de 5 s de antigüedad, R reenvía a N (falla abierta).
4. R2.4 Para vecinos sin `SR`, R se comporta como la baseline (reenvía a todos los vecinos legacy salvo S y O).
5. R2.5 TTL de salida = TTL de entrada − 1. Un TTL entrante mayor que 6 se trata como 6; con TTL 0 o 1 no se reenvía.
6. R2.6 Un paquete cuyo par (`originId`, `packetId`) ya se vio no se reenvía ni se reproduce (deduplicación ya existente, conservada).

### R3. Reparación de cobertura

SI un vecino N con `SR` no incluye a O en su línea `HRD` durante 2 s mientras R recibe voz directa o indirecta de O, ENTONCES EL SISTEMA DEBERÁ reenviar a N los paquetes de O hasta que `HRD` de N incluya a O, aunque R no sea el mejor candidato.

Criterios de aceptación:
1. R3.1 Prueba de simulación: un candidato que "olvida" reenviar (tabla desactualizada) provoca que otro nodo repare en menos de 2,5 s.
2. R3.2 La reparación se desactiva sola cuando `HRD` de N incluye a O durante 2 s consecutivos.
3. R3.3 El tráfico extra de reparación se cuenta y aparece en diagnóstico.

### R4. Reducción medible de retransmisiones

Criterios de aceptación (en el simulador de topologías, con 1 paquete de voz de un origen y TTL 6):
1. R4.1 Cadena de 4 nodos (A–B–C–D, A origen): D oye a A y el total de transmisiones por paquete es ≤ 3. Con la baseline el total es 6.
2. R4.2 Estrella de 6 (líder y 5 miembros que no se ven entre sí, origen = un miembro): todos oyen al origen y el total es ≤ 5 (1 del origen al líder + 4 del líder).
3. R4.3 Malla completa de 5 (hotspot): total de transmisiones = 4 y ningún nodo reenvía. Con la baseline el total es 20.
4. R4.4 Cadena de 7 nodos con TTL 6: el nodo 7 oye al origen (el origen tiene TTL 6 y llega a 6 saltos). El nodo 8 no.
5. R4.5 En las tres topologías, ningún nodo con `SR` queda sin oír al origen aunque el 20 % de las listas `NB` estén desactualizadas (falla abierta y reparación).

### R5. Topología mixta

Criterios de aceptación:
1. R5.1 Una topología combinada (cadena de 3 que termina en un nodo líder con 3 miembros a la vista) entrega la voz de un extremo al otro del conjunto.
2. R5.2 Cuando un nodo pasa de estar en cadena a estar en el hotspot compartido (todos se ven), los relays dejan de ocurrir en menos de 5 s sin configuración del usuario.

### R6. Modo Auto/gateway y puente entre transportes

CUANDO un nodo reenvía un paquete entre transportes (Multipeer y UDP), EL SISTEMA DEBERÁ reenviar el paquete reencapsulado con TTL − 1 y no el paquete original.

Criterios de aceptación:
1. R6.1 En el modo Auto, un paquete que cruza de Multipeer a UDP llega con TTL menor en 1 que el que entró (prueba unitaria sobre el controlador con transportes simulados).
2. R6.2 Un paquete nunca vuelve por el transporte por el que llegó, ni al vecino S ni al origen O.
3. R6.3 Mac Relay y iOS aplican la misma regla (hoy Mac lo trata distinto, `RelaySession.swift:490-491`).

### R7. Criterio unificado de relay

EL SISTEMA DEBERÁ usar el mismo criterio de relay en iOS, Android y Mac (R2), no las heurísticas actuales (más de 1 peer en iOS; nombre con coma en Android).

Criterios de aceptación:
1. R7.1 La decisión de relay es una función pura con las mismas entradas y salidas en las tres plataformas, probada con los mismos vectores de topología.
2. R7.2 Las heurísticas viejas se eliminan o quedan solo en las rutas `Legacy*` del spec 1.

### R8. Datos de campo para revisar el TTL

EL SISTEMA DEBERÁ registrar localmente contadores para revisar si el TTL de 6 es adecuado.

Criterios de aceptación:
1. R8.1 Contadores por sesión: paquetes reenviados, suprimidos (con causa: ya cubierto, no soy el mejor, TTL agotado), duplicados descartados, reparaciones y distribución de saltos por paquete recibido.
2. R8.2 Los contadores se ven en diagnóstico (iOS) y en log (Android y Mac) y se pueden copiar para el análisis. No salen del dispositivo.
3. R8.3 Un documento de revisión en el README de specs fija la fecha de revisión del TTL tras la primera prueba de campo con al menos 4 dispositivos.

### R9. Compatibilidad

Criterios de aceptación:
1. R9.1 Un grupo con un nodo baseline (sin `SR`) mantiene audio entre todos (C1); el nodo baseline recibe de sus vecinos nuevos lo mismo que hoy.
2. R9.2 Los vecinos sin `SR` no cuentan en las listas `NB` de forma que dejen sin cobertura a otros (se tratan como legacy, R2.4).
3. R9.3 `defaultTTL` es 6 en las tres plataformas, igual que la baseline.

## Requisitos no funcionales

- NF1. La decisión de relay para un paquete tarda menos de 1 ms en el dispositivo más lento (medido con un banco unitario).
- NF2. Tamaño de las tablas de vecinos: máximo 32 orígenes (spec 1), cada uno con hasta 5 vecinos.

## Fuera de alcance

- RSSI, Wi-Fi Aware y `WAPerformanceReport` (descartados, requieren emparejado y el soporte de Android no está verificado).
- Autenticación de listas de vecinos (ver riesgo en README).
- Cambio de TTL a un valor distinto de 6.
- Cambio de límite de 5 conexiones (decisión de tamaño de grupo, `design.md` decisión 6).
