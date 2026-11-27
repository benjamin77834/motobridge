# Tareas: headset-audio-profiles
- [x] 1. Modelo y almacén: `HeadsetProfile.swift` (identidad, perfil, UserDefaults).
  - _Requisitos: R1, R3_
- [x] 2. `NetworkBridgeController`: aplicar perfil en `refreshInputs`, guardar en los `didSet`, restablecer, `voiceEnhancement` publicado.
  - _Requisitos: R2, R3, R5_
- [x] 3. UI en la tarjeta de audio: nombre, estado, restablecer, mejora de voz.
  - _Requisitos: R4_
- [x] 4. `HeadsetProfileTests.swift`; los tests existentes siguen pasando.
- [ ] 5. Prueba en dispositivo con AirPods, Ray-Ban Meta e intercom HFP: cambiar de casco y comprobar que se aplican los valores guardados.
- [ ] 6. Android (pendiente, fuera de esta pasada): mismo perfil por nombre de dispositivo de audio + tipo, guardado en SharedPreferences. No tocar `PERFORMANCE_MODE_LOW_LATENCY`.
