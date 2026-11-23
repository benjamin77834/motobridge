# Requisitos: link-liveness-heartbeat

## Objetivo

Detectar en unos 2 segundos que un vecino directo dejó de estar, reconectarlo solo cuando vuelva a estar en rango, y mantener el enlace vivo con la pantalla bloqueada o la app en segundo plano mientras haya enlace. Aplica a los dos caminos de red (Multipeer y UDP/Bonjour) y a iOS, Android y Mac.

## Dependencias

- Spec 1 `protocol-capabilities-baseline` (capacidad `HB`, tabla por vecino, id de vecino en recepción).

## Origen y supuestos

- Entrada: estudio §2 sección C; decisión del usuario 7 (pantalla bloqueada y rejoin automático).
- Hecho del código: la presencia va cada 2 s (`NetworkBridgeController.swift:822-850`); el radar marca "perdido" a los 7 s (`:726-733`) sin afectar al transporte; el transporte UDP de iOS solo reacciona a `.failed`/`.cancelled` (`LocalNetworkTransport.swift:198-218`); Android y Mac toleran 30 s sin tráfico (`net/LocalNetworkTransport.kt:172-190`, `UniversalTransport.swift:181-188`).
- Hecho del código: `UIBackgroundModes = audio` (`Info.plist:51-54`) y `isIdleTimerDisabled = true` ya existen (`NetworkBridgeController.swift:1310`, se revierte en `:1572`). Android ya usa servicio en primer plano de micrófono con `WakeLock` y `WifiLock` (`BridgeService.kt`). Mac ya usa `ProcessInfo.beginActivity` (`RelaySession.swift:266`).
- **NO CONFIRMADO por Apple:** si Multipeer o Network framework mantienen la conexión con la app en segundo plano y `UIBackgroundModes = audio`. Apple documenta que Multipeer deja de buscar y anunciar en segundo plano (foro 836124) y que la red se detiene si la app se suspende (foro 695125). Este spec no asume el resultado: exige una prueba en dispositivo (R7) y diseña para ambos desenlaces.
- Supuesto A1: umbral de caída 2 s y keepalive 500 ms son los que pidió el usuario; se tratan como constantes ajustables tras el campo.
- Supuesto A2: "rejoin en un tiempo razonable" se fija en p90 ≤ 8 s tras volver a estar en rango. Propuesto por el arquitecto y **aceptado por el usuario** (README, respuesta 5). Se mide en campo y se puede ajustar con datos.

## Requisitos funcionales (EARS)

### R1. Keepalive rápido solo con pares que lo soportan

MIENTRAS un vecino directo declare la capacidad `HB`, EL SISTEMA DEBERÁ enviarle un keepalive cada 500 ms (±100 ms).

Criterios de aceptación:
1. R1.1 En una captura de 30 s entre dos nodos con `HB`, cada nodo envía entre 56 y 64 keepalives.
2. R1.2 Un vecino sin `HB` no recibe keepalives y se le sigue enviando la presencia cada 2 s como hoy.
3. R1.3 El keepalive no se retransmite por malla (TTL de malla 1, o sin cabecera de malla si el vecino está en formato directo). Una prueba de 3 nodos en cadena verifica que el nodo intermedio no lo reenvía.
4. R1.4 Un keepalive no produce sonido, evento visual ni cambio en el radar en una build baseline (prueba con la baseline como vecino: no recibe keepalives por R1.2).

### R2. Detección de caída por silencio

SI un vecino directo con `HB` no envía ningún paquete (keepalive, audio o presencia) durante 2 s, ENTONCES EL SISTEMA DEBERÁ marcarlo como caído, quitarlo de la lista de destinos de envío y de relay y reflejarlo en el radar.

Criterios de aceptación:
1. R2.1 Con dos dispositivos, apagar el Wi-Fi de uno hace que el otro lo marque caído entre 2,0 s y 2,6 s después del último paquete recibido (medido en el log).
2. R2.2 Cualquier paquete recibido reinicia el contador de silencio, no solo los keepalives.
3. R2.3 Para un vecino sin `HB`, el sistema conserva el comportamiento baseline: la baja del radar a los 7 s y las tolerancias de 30 s de Android y Mac.
4. R2.4 Un salto de pérdida de 1 a 3 keepalives consecutivos (hasta 1,5 s) no marca caída.
5. R2.5 El radar usa el estado de liveness del transporte y no su propio temporizador de 7 s cuando el vecino es `HB`.

### R3. Recuperación y estado "recuperado"

CUANDO un vecino caído vuelve a enviar paquetes, EL SISTEMA DEBERÁ marcarlo como recuperado tras 2 keepalives consecutivos y volver a incluirlo en el envío y el relay.

Criterios de aceptación:
1. R3.1 El paso caído a recuperado requiere 2 paquetes recibidos en menos de 1,5 s.
2. R3.2 Un vecino que oscila (cae y vuelve más de 3 veces en 10 s) queda en estado "inestable" durante 10 s y su calidad de enlace (spec 4) se penaliza.
3. R3.3 La recuperación no reproduce el timbre de conexión cuando el vecino estuvo caído menos de 10 s. El timbre solo suena con peers nuevos, como hoy.

### R4. Rejoin automático

CUANDO un vecino caído vuelve al rango, EL SISTEMA DEBERÁ reconectarse sin intervención del usuario, con reintentos con retroceso, mientras el bridge esté activo.

Criterios de aceptación:
1. R4.1 Con iPhone↔iPhone, iPhone↔Android y iPhone↔Mac, apagar y encender el Wi-Fi o alejar y acercar un dispositivo reconecta sin tocar ninguna pantalla, con p90 ≤ 8 s sobre al menos 10 repeticiones por combinación.
2. R4.2 Los reintentos esperan 1 s, 2 s, 4 s y desde ahí 5 s entre intentos, sin límite de intentos mientras el bridge esté activo. Un evento de descubrimiento (Bonjour o Multipeer) del vecino cancela la espera y reintenta de inmediato.
3. R4.3 Solo uno de los dos extremos inicia la reconexión (el de `ID` menor, igual que `shouldInvite` en Multipeer), de forma que no se crucen invitaciones. Si el que debe iniciar no lo hace en 5 s, el otro inicia.
4. R4.4 Con el bridge detenido por el usuario, no se reintenta nada.
5. R4.5 En modo manual (`autoConnect` apagado) el sistema no reconecta solo, igual que hoy (`PeerBridgeSession.swift:232-250`).

### R5. Presupuesto de tráfico de control

EL SISTEMA DEBERÁ mantener el tráfico de control (keepalive más presencia) en menos de 4 kbps por nodo con 5 vecinos, medido a nivel de payload UDP.

Criterios de aceptación:
1. R5.1 Medición con 5 vecinos durante 60 s: payload de control saliente ≤ 4 kbps en promedio.
2. R5.2 El keepalive no supera 24 bytes de payload de aplicación.

### R6. Enlace activo con pantalla bloqueada o app en segundo plano

MIENTRAS el bridge esté activo y haya al menos un vecino conectado o en reintento, EL SISTEMA DEBERÁ mantener la app activa para seguir enviando y recibiendo voz con la pantalla bloqueada o la app en segundo plano.

Criterios de aceptación:
1. R6.1 iOS: la sesión de audio queda activa y el modo de fondo `audio` permanece declarado; `isIdleTimerDisabled` permanece en `true` mientras el bridge esté activo y vuelve a `false` al detenerlo (comportamiento ya existente, se protege con prueba).
2. R6.2 iOS: tras una interrupción de audio (llamada, Siri, alarma), al terminar la interrupción el sistema reactiva la sesión de audio y el motor, y reconecta (R4) sin intervención.
3. R6.3 iOS: al volver a primer plano, el sistema reinicia el descubrimiento (Multipeer y Bonjour) si estuvo detenido y refresca la lista de vecinos en menos de 3 s.
4. R6.4 Android: el servicio en primer plano de micrófono, `WakeLock` y `WifiLock` permanecen activos mientras el bridge esté activo; un reinicio del servicio por el sistema no deja al bridge sin enlace (reconecta por R4).
5. R6.5 Mac: la actividad `beginActivity` permanece activa mientras el bridge esté activo (ya existe, se protege con prueba manual de 30 min con la ventana oculta).
6. R6.6 Prueba de campo de 30 min con pantalla bloqueada: voz bidireccional audible entre dos iPhones, entre iPhone y Android y entre iPhone y Mac, con registro de cuándo (si alguna vez) se cae el enlace.

### R7. Prueba en dispositivo de Multipeer y Network en segundo plano

EL SISTEMA DEBERÁ contar con una matriz de pruebas en dispositivo que determine, por camino de red, si el enlace sobrevive en segundo plano y con pantalla bloqueada, y DEBERÁ guardar el resultado como configuración que el selector de camino (spec 5) consulta.

Criterios de aceptación:
1. R7.1 La matriz cubre, para cada camino (Multipeer, UDP/Bonjour con la API actual; más Network iOS 26 cuando exista el spec 5): app en primer plano, segundo plano con sesión de audio activa y voz en curso, segundo plano en silencio, pantalla bloqueada, con duraciones de 1, 5 y 30 min.
2. R7.2 Cada celda registra: ¿la conexión sobrevive?, ¿se oye voz?, ¿cuánto tarda en reconectar al volver?, versión de iOS, modelo de iPhone, con fecha.
3. R7.3 Los resultados se documentan en `KNOWN_LIMITATIONS.md` y se traducen a una tabla de configuración `backgroundPathPreference` (camino preferido por estado de la app) en el código.
4. R7.4 Mientras no haya resultado para una celda, el valor por defecto es "no se asume que sobrevive": al pasar a segundo plano el sistema mantiene todos los caminos activos y, si uno cae, usa el otro.

## Requisitos no funcionales

- NF1. El temporizador de keepalive no despierta la CPU más de 2 veces por segundo por transporte (un solo temporizador compartido por transporte, no uno por vecino).
- NF2. Con un vecino ausente, el consumo de reintentos es de como máximo 1 intento por 5 s.

## Fuera de alcance

- Métrica de calidad de enlace y relay selectivo (spec 4).
- Elección entre caminos Multipeer y Network (spec 5); aquí solo se mide cada camino por separado.
- Cifrado.
- Notificaciones locales para avisar al rider de que la app se detuvo (backlog).
