# Diseño: headset-audio-profiles
## Decisiones
- Clave `"<nombre en minúsculas>|<familia>"`. La familia reemplaza al tipo exacto de puerto porque los mismos AirPods aparecen como A2DP (salida) y HFP (entrada); con el tipo exacto tendrían dos perfiles.
- Limitación: iOS no expone un identificador único; dos cascos del mismo modelo y nombre comparten perfil. Quien quiera perfiles distintos debe renombrar uno de los cascos en Bluetooth.
- Persistencia: un diccionario `[clave: HeadsetProfile]` codificado en JSON bajo la clave `headsetProfiles` de UserDefaults. Datos ilegibles se tratan como "sin perfil".
## Componentes (iOS)
- `MotoBridge/Core/Bridge/HeadsetProfile.swift`: `HeadsetProfile` (Codable), `HeadsetIdentity.key(portName:portType:)`, `HeadsetProfileStore` (UserDefaults inyectable).
- `NetworkBridgeController`:
  - `refreshInputs()` mantiene su ajuste síncrono por calidad en `audioIO` y después, en el hilo principal, llama `applyHeadsetProfile(key:name:defaults:)`. Sin perfil guardado, los valores por defecto solo se aplican al cambiar de audífono; con perfil, se aplica en cada refresco.
  - Los `didSet` de `micGain`, `speakerGain`, `noiseGate` y el nuevo `voiceEnhancement` llaman `saveActiveHeadsetProfile()`, que no hace nada mientras `applyingHeadsetProfile` es true o no hay audífono activo.
  - `resetActiveHeadsetProfile()` borra el perfil y aplica los valores por defecto.
- `handleRouteChange` ya llama `refreshInputs`, así que el perfil se aplica al conectar o cambiar de ruta sin tocar `scheduleIntercomMode` ni `applyIntercomMode`.
- UI: bloque en la tarjeta de audio de `NetworkBridgeView` (interruptor de mejora de voz, nombre y estado del perfil, botón de restablecer).
## Pruebas
`MotoBridgeTests/HeadsetProfileTests.swift`: clave (normalización, A2DP = HFP, puertos integrados), guardado y carga entre instancias, independencia entre perfiles, borrado, datos corruptos.
## Pendiente
Android: no implementado en esta pasada.
