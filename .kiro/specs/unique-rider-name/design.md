# Diseño: unique-rider-name
## Decisiones
- Nombre editable con valor automático por defecto derivado del UID (el número de serie no es accesible en iOS).
- Sufijo del UID solo ante colisión detectada; el automático ya es casi siempre único.
- Pregunta de nombre decidida: SÍ, máx. 2 veces, sin bloquear el audio (antes era punto abierto).
- Android: prefijo `Android` en vez de `Build.MODEL`.
## Componentes
- iOS y Mac: `MotoBridge/Core/Network/RiderIdentity.swift` (Foundation puro, compartido con Mac Relay vía `project.yml`): `RiderName` (suffix, automatic, sanitize, effective, collides, current) y `RiderNamePromptPolicy` (UserDefaults inyectable: `shouldPrompt(.appOpen/.bridgeStart)`, `markShown`, `save`).
- iOS: `PeerBridgeSession` y `LocalNetworkTransport` toman `RiderName.current(...)`. `NetworkBridgeController`: `checkNamePrompt`, `submitNamePrompt`, `skipNamePrompt`, `detectNameCollision` (en `onPeersChange`), `rebuildTransportsForName` (usa `applyModeTransports`, también cubre el modo puente). `NetworkBridgeView`: alerta con campo y tarjeta "Mi nombre" (activa también con el bridge en marcha).
- Mac Relay: `RelaySession` usa `RiderName` con `relayName`/`relayDeviceUID`; `showNameNotice` y `saveName`; tarjeta "Mi nombre" en `RelayApp`. El `MCPeerID` es fijo: el nombre guardado se aplica al reiniciar la app.
- Android: `net/RiderIdentity.kt` (mismas funciones y `KeyValueStore` para probar sin Android). `BridgeController`: `deviceUid` (ANDROID_ID, o UUID si falta o es el valor roto conocido), `checkNamePrompt`, diálogo en `MainActivity`, aplicación al detener.
- Reloj: sin cambios; recibe los nombres de los peers desde el iPhone.
## Límites conocidos
- La colisión se detecta cuando el otro peer es visible. En UDP el transporte descarta el servicio con el mismo nombre ("yo mismo"), así que ahí la detección es mejor esfuerzo; el nombre automático evita casi todos los casos.
- Con apps viejas en el grupo siguen los nombres repetidos (R4).
## Pruebas
- iOS: `MotoBridgeTests/RiderNameTests.swift` (generación, colisión, id privado distinto, política de pregunta: cuándo, guardado, omitido, máx. 2).
- Android: `RiderNameTest.kt` (mismos casos).
- Mac Relay: sin target de pruebas; comparte `RiderIdentity.swift` (cubierto por las pruebas de iOS) y compila.
