# KNOWN_LIMITATIONS.md — MotoBridge

Limitaciones conocidas y documentadas. Ver evidencia técnica en `FEASIBILITY_REPORT.md`.

## L1 — Bridge Bluetooth↔Bluetooth en un solo iPhone: NO VIABLE 🔴
iOS no permite, con APIs públicas, tomar audio de un intercom Bluetooth y enviarlo simultáneamente a otro intercom Bluetooth. Causas acumuladas:
- CoreBluetooth no accede al audio Bluetooth Classic (HFP/A2DP); requeriría MFi (los intercoms no lo son).
- `AVAudioSession` expone una sola ruta de input de voz a la vez (regla last-in) y no soporta input HFP de un BT + salida hacia otro BT.

**Mitigación:** bridge por red entre dos iPhones (Alternativa A). No se implementan hacks (regla #18/#24).

## L2 — Detección de dispositivos ≠ CoreBluetooth
Los intercoms de moto son Bluetooth Classic; **no** aparecen ni se controlan por CoreBluetooth (solo BLE). La app deriva su estado "conectado" desde `AVAudioSession.currentRoute`. El match FreedConn/Hysnox se hace por **nombre de puerto** (heurística), porque iOS no etiqueta el dispositivo por fabricante.

## L3 — Calidad de audio HFP
La voz bidireccional Bluetooth (HFP) es mono y de baja calidad por diseño del perfil. `allowBluetoothA2DP` da alta calidad pero **solo salida**, sin micrófono simultáneo.

## L4 — No verificado en hardware real
FASES 1 y 3 están verificadas en **simulador** (compila, tests pasan). El simulador **no** tiene Bluetooth ni intercoms reales, así que el veredicto experimental de rutas y el comportamiento de HFP **deben confirmarse en un iPhone físico** con FreedConn + Hysnox (FASE 7). Conforme a la regla #24, aún no se afirma que funcione en hardware.

## L5 — `micEnabled` y PTT en Dashboard son UI
En esta fase el toggle de micrófono y el botón PTT son de interfaz; el enrutamiento real de captura/reproducción se implementa en FASE 5. No mueven audio todavía.

## L6 — Bridge sección del Dashboard
El botón "PROBAR BRIDGE" invoca `AudioBridge.prepare()`, que intencionadamente entra en estado `error` con el mensaje de limitación de iOS. Es el comportamiento correcto y honesto para el hardware objetivo, no un bug.


---

## Hallazgos en hardware real (prueba del Network Bridge, 2026-09-16)

## L7 — Micrófono del FreedConn T-COM VB NO funciona vía HFP con iOS
Probado en hardware real con el medidor de nivel de la app:
- **Hysnox**: micrófono HFP funciona (el medidor de nivel sube al hablar). ✅
- **FreedConn T-COM VB**: micrófono HFP **no entrega señal** a iOS (el medidor queda en cero), tanto en iPhone como en iPad. Su **altavoz sí funciona** (reproduce el audio recibido).

Conclusión: es una limitación del **hardware/firmware del FreedConn T-COM VB**, no de la app ni del dispositivo Apple (se confirmó intercambiando iPhone/iPad: el fallo sigue al casco). Este intercom expone bien la salida de audio pero su perfil HFP con micrófono es inutilizable desde apps de iOS. No se puede corregir por software sin tocar firmware (prohibido por la regla #18).

**Mitigación implementada:** selector de entrada de audio en la app. En el lado del FreedConn se puede usar **AirPods o audífonos con micrófono** para capturar la voz, dejando el FreedConn solo como salida (o usando otro dispositivo completo). Verificado: **AirPods funcionan como micrófono** tras el arreglo de reinicio del engine.

## L8 — Cambiar de entrada requiere reiniciar el AVAudioEngine
`setPreferredInput` no basta: el `inputNode` del engine queda ligado a la ruta anterior. Hay que **detener y reiniciar el engine** para que tome el nuevo micrófono. Implementado en `AudioIO.restart()`.

## L9 — A2DP vs HFP (confirmado en hardware)
Con `.allowBluetoothA2DP` activo, iOS enruta la salida por A2DP (alta calidad, **sin micrófono**) y el micrófono del casco Bluetooth deja de funcionar. Para intercom bidireccional hay que usar **solo HFP** (mono, calidad telefónica 8 kHz). Es un compromiso inevitable: micrófono ↔ calidad de audio.

## Recomendación de compatibilidad
Para el bridge bidireccional, cada lado necesita un dispositivo de audio con **micrófono HFP funcional**: AirPods, audífonos con micrófono, o intercoms que sí expongan HFP (como el Hysnox). Se recomienda mantener una **lista de cascos compatibles** verificados con el medidor de nivel de la app.


---

## L10 — Cancelación de eco (AEC)
Se habilita el voice processing nativo de iOS (`setVoiceProcessingEnabled`). Reduce el eco en manos libres bidireccional. No es perfecto en todos los dispositivos ni con todos los cascos; si hay acople residual, usar push-to-talk o separar los dispositivos. En moto real (cascos lejanos entre motos) el eco no es problema.

## L11 — Apple Watch no puede ser nodo del bridge (pero SÍ es PTT remoto)
watchOS no dispone de MultipeerConnectivity ni de streaming de audio en vivo de baja latencia para apps de terceros. El Apple Watch **no** puede reemplazar a un iPhone/iPad como extremo del bridge (el audio no pasa por el Watch).

**Implementado:** app watchOS (`MotoBridgeWatch`) con un **botón de push-to-talk remoto**. Al mantenerlo, el Watch envía el comando por `WatchConnectivity` y el iPhone activa la transmisión; el audio sigue pasando por el iPhone. El Watch también muestra si el bridge está conectado. Ideal para moto: hablar sin soltar el manillar.

## L12 — Android: fase separada
El transporte actual (MultipeerConnectivity) es exclusivo de Apple. Para incluir Android se requiere una app nativa Android y un transporte neutral multiplataforma (WebRTC o sockets UDP + mDNS/Bonjour). Es una fase de proyecto aparte, no un ajuste menor.


## L13 — Ray-Ban Meta: reproducen (salida) pero su micrófono NO está disponible
Probado en hardware real:
- **Salida (escuchar)**: ✅ **funcionan** — reproducen el audio del bridge, aunque a **volumen bajo**. Mitigado con la nueva **ganancia de salida ajustable** (`outputGain`, slider "Volumen de escucha" 1×–6×).
- **Entrada (micrófono)**: ❌ **no disponible** (el medidor de nivel queda en cero). Las gafas reservan su micrófono para el ecosistema de la app de Meta (grabación, llamadas de WhatsApp/Messenger, comandos de voz) y **no lo exponen como entrada HFP genérica** a `AVAudioSession`. Restricción intencional de Meta, no corregible por software (forzarlo requeriría APIs privadas, prohibidas por la regla #18).

Uso recomendado: Ray-Ban Meta como **salida** (con volumen de escucha subido) + AirPods/audífono con micrófono o intercom con HFP funcional (Hysnox) como **entrada**. Recordar el límite de iOS: mic de un dispositivo + salida de otro **no** es posible en el mismo teléfono a la vez.
- Recordatorio (límite iOS): en un mismo teléfono no se puede combinar "mic de un dispositivo + salida de otro" simultáneamente; usar un dispositivo completo (mic+altavoz) por lado.

## Lista de compatibilidad de micrófono (verificada con el medidor de nivel)
| Dispositivo | Micrófono HFP en iOS | Notas |
|---|---|---|
| Hysnox | ✅ Sí | mic + altavoz OK |
| AirPods | ✅ Sí | mic + altavoz OK (mono/HFP) |
| FreedConn T-COM VB | ❌ No | solo salida; mic HFP no entrega señal |
| Ray-Ban Meta | ❌ No | mic reservado a la app de Meta; **salida sí (volumen bajo, subir con ganancia de escucha)** |
