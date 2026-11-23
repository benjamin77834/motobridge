# Tareas: hotspot-rider-guide

Independiente de los demás specs.

- [ ] 1. Redacción y validación del contenido
  - [ ] 1.1 Confirmar la UI de Android (`MainActivity.kt`: Compose o vistas) y la ubicación del botón en `NetworkBridgeView.swift`.
  - [ ] 1.2 Revisar con el usuario el texto de la decisión 3.
  - CT: texto aprobado por el usuario; sin cifras de alcance (R5.1).
  - _Requisitos: R2, R3, R4, R5_

- [ ] 2. Validar pasos en dispositivos
  - [ ] 2.1 Android: comprobar los pasos de Samsung One UI en un S25 con el Android actual.
  - [ ] 2.2 iPhone: comprobar el interruptor en un iPhone 12 o posterior.
  - CT: pasos corregidos según lo observado; la fecha y versión del sistema anotadas en un comentario del archivo de contenido.
  - Pruebas: manual con dispositivos.
  - _Requisitos: R2.1, R3.1, R3.2_

- [ ] 3. iOS
  - [ ] 3.1 `HotspotGuideView.swift` con tamaño de texto dinámico y etiquetas de VoiceOver.
  - [ ] 3.2 Botón de entrada en `NetworkBridgeView.swift`.
  - CT: R1.1, R1.4, R6.1 a R6.3.
  - Pruebas: unitaria de palabras prohibidas; manual de acceso y de VoiceOver.
  - _Requisitos: R1, R2, R4, R6_

- [ ] 4. Android
  - [ ] 4.1 Cadenas en `strings.xml` y pantalla o diálogo en `MainActivity.kt` con descripciones de TalkBack.
  - CT: R1.2, R1.4, R3.1, R6.1 a R6.3.
  - Pruebas: unitaria de palabras prohibidas sobre `strings.xml`; manual de acceso y de TalkBack.
  - _Requisitos: R1, R3, R4, R6_

- [ ] 5. Mac Relay
  - [ ] 5.1 Sección de ayuda con el texto de iOS en `RelayApp.swift` (no de `RadarView`).
  - CT: R1.3.
  - Pruebas: manual.
  - _Requisitos: R1, R2, R4_

- [ ] 6. Documentación
  - [ ] 6.1 Mención breve en `README.md`; la página de la tienda solo si el usuario lo pide.
  - CT: el README describe dónde está la guía.
  - _Requisitos: R5.3_
