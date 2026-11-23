# Diseño: link-liveness-heartbeat

## Visión general

Hoy el transporte no sabe cuándo un vecino se fue: UDP no avisa y solo se detectan `.failed` y `.cancelled`, y el radar tiene su propio reloj de 7 s. Este spec añade un rastreador de liveness por vecino directo en la capa de transporte, alimentado por cualquier paquete recibido, más un keepalive de 500 ms que se envía solo a pares con la capacidad `HB`. Cuando el rastreador declara caído a un vecino, el transporte lo saca del envío y arranca la reconexión con retroceso. Además fija las reglas para mantener el enlace con la pantalla bloqueada y exige una prueba en dispositivo del comportamiento en segundo plano, que Apple no confirma.

**Stack:** Swift/SwiftUI (iOS 17+ en este spec; el cambio de mínimo ocurre en el spec 5), Multipeer Connectivity y `NWConnection`/`NWListener`/`NWBrowser` ya existentes, Kotlin con `NsdManager` y sockets UDP en Android, Swift en Mac Relay. Sin dependencias nuevas.

## Decisión 1: keepalive como paquete de presencia mínimo, solo a pares `HB`

**Elegido:** el keepalive viaja como un paquete `VoiceChannelType.presence` (tipo ya conocido por todas las versiones) con payload de una línea `HB=<contador>` y sin nombre. Se envía por unicast solo a vecinos con `HB`. Un vecino legacy nunca lo recibe, así que no existe el riesgo de clic (C3) ni de rider fantasma: el parser legacy descarta presencias con primera línea vacía y además no recibe el paquete.

El keepalive usa el encuadre que ese vecino espera (con cabecera de malla de TTL 1 si el vecino está en formato malla; sin cabecera si está en directo). Por eso se necesita el id de vecino del spec 1 y una función "armar para este vecino".

Alternativas descartadas:
- *Reducir la presencia completa a 500 ms*: cuadruplica el tráfico del nombre, ALT y BAT, y la malla lo retransmite. El estudio lo marca como riesgo menor.
- *Tipo de canal nuevo*: viola C3.
- *Usar solo el audio como señal de vida*: en silencio no hay audio, y en push-to-talk pasan segundos sin tráfico.
- *Pings del sistema (TCP keepalive)*: no existen para UDP.

## Decisión 2: rastreador de liveness por vecino en el transporte

**Elegido:** un componente puro `LivenessTracker` por transporte, con reloj inyectado. Estados por vecino: `desconocido`, `vivo`, `caído`, `inestable`. Entradas: "se recibió un paquete del vecino X en el instante T" y "tick del temporizador". Salidas: eventos `caído(X)` y `recuperado(X)`.

Reglas:
- Se registra el último paquete recibido (`lastRx`) con cualquier tipo.
- `vivo` pasa a `caído` si `ahora - lastRx > 2,0 s` (constante `downAfter`).
- `caído` pasa a `vivo` tras 2 paquetes en menos de 1,5 s (constante `upAfterPackets`).
- Más de 3 transiciones en 10 s activan `inestable` por 10 s; el spec 4 lo usa para la calidad.
- Un solo temporizador de 250 ms por transporte revisa todos los vecinos (NF1), y el envío de keepalive usa el mismo reloj (cada 500 ms).
- Un vecino sin `HB` queda con `lastRx` solo informativo y no genera eventos (R2.3).

Dónde vive: lógica pura en `MotoBridge/Core/Network/LivenessTracker.swift` (compilada también en el Mac Relay como `MeshRelay.swift`, `project.yml:62-69`) y `net/LivenessTracker.kt` en Android. Pruebas unitarias con reloj falso.

Alternativas descartadas:
- *Que la UI (radar) siga siendo la fuente*: solo existe en iOS y mezcla presentación con red.
- *Un temporizador por vecino*: más despertares de CPU y batería, más difícil de probar.
- *Umbral de 2 s para todos los pares*: una build baseline en el grupo no envía nada cada 500 ms y se marcaría caída falsamente. Por eso es solo con `HB`.

## Decisión 3: reconexión con retroceso y desempate

**Elegido:** al recibir `caído(X)`:
1. Se cierra el estado local del vecino (se saca de los destinos de envío y del relay).
2. Se programa un reintento a 1 s, luego 2 s, 4 s y 5 s constante, sin tope de intentos mientras el bridge esté activo (R4.2).
3. Un evento de descubrimiento de X (navegador Bonjour o Multipeer) cancela la espera y reintenta ya.
4. Solo inicia el extremo con `ID` menor; si pasan 5 s sin conexión, el otro también inicia. El desempate de Multipeer (`shouldInvite`, `PeerBridgeSession.swift`) se conserva y se extiende al transporte UDP.

El retraso fijo de 2 s de Multipeer (`PeerBridgeSession.swift:236`) se reemplaza por este esquema. Se mantiene `timeout: 10` de `invitePeer`, pero un intento no se espera hasta los 10 s para programar el siguiente: se cuenta el siguiente retroceso desde el fallo del intento.

Alternativas descartadas:
- *Reintento fijo cada 2 s*: se acumulan invitaciones si el timeout es de 10 s.
- *Retroceso exponencial sin tope*: un rider que vuelve tras 2 minutos esperaría demasiado. El tope de 5 s limita el peor caso.
- *Reconectar solo desde el extremo que cayó*: no se sabe quién cayó.

## Decisión 4: segundo plano y pantalla bloqueada

Lo que ya existe y se conserva: `UIBackgroundModes = audio`, `isIdleTimerDisabled`, servicio en primer plano de micrófono en Android con `WakeLock` y `WifiLock`, `beginActivity` en Mac.

Lo que se añade:
- **iOS:** observadores de ciclo de vida y de interrupción de audio. Al volver de una interrupción (el observador ya existe: `NetworkBridgeController.swift:603`, `AudioSessionManager.swift:202`), reactivar la sesión (`setActive(true)`), reiniciar el motor de audio y llamar a la reconexión del punto 3. Al pasar a primer plano, reiniciar el navegador Multipeer y el navegador Bonjour (Multipeer deja de buscar y anunciar en segundo plano, foro 836124).
- **Tabla `backgroundPathPreference`:** para cada estado de app (primer plano, segundo plano, bloqueado) y cada camino, una bandera `sobrevive`: `sí`, `no` o `desconocido`. Valor inicial: `desconocido` para todos. El selector de camino del spec 5 la consulta. Se actualiza solo cuando la prueba del R7 produce evidencia.
- **Política mientras es `desconocido`:** mantener todos los caminos abiertos (R7.4). Si el sistema suspende un camino, el otro sigue; los cambios de camino se manejan como una caída más.

**Hipótesis (no hecho):** con la sesión de audio activa y el micrófono en uso, el proceso no se suspende y las conexiones UDP de Network framework deberían seguir funcionando; Multipeer puede dejar de descubrir pero conservar sesiones ya establecidas. Ambas afirmaciones se tratan como hipótesis hasta que la matriz del R7 las confirme o descarte.

Alternativas descartadas:
- *Prometer que funciona en segundo plano sin probarlo*: Apple no lo confirma.
- *Tarea de fondo con `beginBackgroundTask`*: da un máximo de unos segundos, no sirve para una ruta de horas. Se descarta.
- *Modo de fondo `voip`*: obliga a usar PushKit y CallKit con llamadas reales, y el App Store lo revisa por uso VoIP real. **El usuario autorizó evaluarlo** (README, respuesta 6) si `audio` no basta, con dos antecedentes que él dio: la app debe estar siempre activa mientras haya enlace, y Apple rechazó antes un build por un crash al arrancar con `voip` y `location` (ya quitados). Esos dos modos no están hoy en `Info.plist` (solo `audio`). No se adopta sin evidencia.
  - **Regla de decisión:** la matriz del R7 (tarea 6) decide. Si con `audio` el enlace sobrevive en segundo plano y con pantalla bloqueada durante la prueba de 30 min, `voip` no se añade. Si no sobrevive, se prueba `voip` en un build de depuración local antes de cualquier TestFlight, con el arranque cubierto por una prueba para no repetir el crash que Apple rechazó.
  - **Riesgo de revisión que se documenta, no se asume resuelto:** Apple puede rechazar `voip` si la app no es VoIP real. La decisión final con la evidencia queda escrita en `KNOWN_LIMITATIONS.md` y en el README.
  - **Nota sobre CallKit:** el código ya tiene `useCallKit` activado por defecto (hallazgo del informe de Daniela, `.agents/tasks/daniela-one-way-audio.md`); la tarea 6 verifica qué hace hoy antes de planear cambios.

## Archivos a modificar

- iOS: `PeerBridgeSession.swift` (reintento, liveness, reinicio de navegador), `LocalNetworkTransport.swift` (liveness UDP, reintento, desempate por `ID`), `NetworkBridgeController.swift` (timer de presencia `:822-850`, radar `:726-733`, observadores de ciclo de vida), `AudioTransport.swift` (eventos `caído` y `recuperado`), nuevo `LivenessTracker.swift`, `KNOWN_LIMITATIONS.md`.
- Android: `net/LocalNetworkTransport.kt` (reemplazar la tolerancia de 30 s solo para vecinos `HB`, `:172-190`), `BridgeController.kt` (`:344-358`), `BridgeService.kt` (comprobar reinicio), nuevo `net/LivenessTracker.kt`.
- Mac: `UniversalTransport.swift` (`:181-188`), `RelaySession.swift` (presencia `:408-415`, Multipeer), `project.yml` (agregar `LivenessTracker.swift` a sources).

## Manejo de errores

| Operación | Falla | Tipo | El llamador recibe | Log |
|---|---|---|---|---|
| Enviar keepalive | `send` devuelve error | Recuperable | Se cuenta; 3 errores seguidos hacia un vecino equivalen a silencio de salida y se registra | `debug`; `warning` al 3.º |
| Detectar caída | Falso positivo (vecino vivo marcado caído) | Recuperable | El vecino se recupera por R3; el usuario ve un parpadeo en el radar | `info` |
| Reconectar | Intento falla por tiempo (Multipeer `timeout: 10`) | Recuperable | Se programa el siguiente retroceso | `info` por intento |
| Reconectar | Listener o navegador en estado `.failed` | Recuperable | Se recrea el listener o navegador con retroceso de 1 s a 5 s | `warning`, evento en pantalla |
| Reactivar sesión de audio | `setActive(true)` lanza error tras interrupción | Recuperable | Reintenta a 1 s, 2 s y 4 s; si sigue fallando, evento visible "Audio no disponible" y se mantiene el enlace de red | `error` |
| Servicio Android reiniciado por el sistema | Se pierde el estado | Recuperable | Reconecta por R4 | `warning` |
| Permiso de red local revocado | Bonjour no descubre | Fatal para ese camino | Estado `Sin conexión` y mensaje existente de permisos | `error` |

## Validación de entradas

| Entrada | Obligatoria | Tipo y límite | Si falla |
|---|---|---|---|
| `HB=<contador>` | Sí en keepalive | Entero sin signo de hasta 10 dígitos | Se ignora el contador pero el paquete cuenta como señal de vida |
| Paquete de un id de vecino desconocido | n/a | n/a | Se registra el vecino como `desconocido` y no genera caída |
| Constantes (`downAfter`, intervalos) | Sí | Valores fijos en una estructura de configuración | No se leen de entrada externa |

## Invariantes

- **Un vecino `caído` nunca recibe voz ni relay.** La aplica el transporte al armar la lista de destinos de `sendAudio`, porque es la única capa que conoce las conexiones físicas.
- **Solo hay un reintento activo por vecino.** La aplica el componente de reconexión del transporte, porque el desempate depende de ese estado.
- **El keepalive nunca llega a un par sin `HB`.** La aplica la función de armado para el vecino, consultando la tabla del spec 1 (consulta por defecto = falso).

## Testabilidad

Unitarias: `LivenessTracker` con reloj falso (caída a 2 s, recuperación con 2 paquetes, oscilación, vecino sin `HB`); calculadora de retroceso (1, 2, 4, 5, 5); presupuesto de bytes del keepalive; armado de keepalive por encuadre.

Integración: dos transportes UDP locales en el mismo proceso con un puerto que se cierra y se reabre (caída y recuperación); en Android, pruebas instrumentadas solo si ya existe infraestructura (no se asume).

Campo (dispositivos): R2.1, R4.1 con 10 repeticiones por combinación, R5.1 con captura de paquetes o contador interno, R6.6 y la matriz de R7. La prueba de segundo plano no se puede automatizar y es parte del criterio de terminado.
