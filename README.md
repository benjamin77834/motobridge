# Mono Bridge

Intercomunicador de motocicleta entre teléfonos. Conecta a varios motociclistas por red local (WiFi/hotspot) para hablar en grupo, con canal privado, emergencia y compatibilidad iPhone/Android.

## Estructura del repositorio

- **`web/`** — Sitio web / landing page (se despliega en AWS Amplify).
- **`MotoBridge/`** — App iOS (SwiftUI). Se abre con `MotoBridge.xcodeproj` (generado con XcodeGen desde `project.yml`).
- **`MotoBridgeWatch/`** — App para Apple Watch (push-to-talk remoto).
- **`android/`** — App Android (Kotlin + Jetpack Compose).
- **`store/`** — Material para las tiendas (íconos, capturas, textos, política de privacidad).
- **`PROTOCOL.md`** — Protocolo de red neutral para interoperar iOS ↔ Android.

## Sitio web (Amplify)

El sitio estático está en `web/`. La configuración de despliegue está en `amplify.yml` (baseDirectory: `web`).

Para desarrollo local, abre `web/index.html` en el navegador.

## Apps

- **iOS:** `xcodegen generate && open MotoBridge.xcodeproj`
- **Android:** abrir la carpeta `android/` en Android Studio.

## Características
- Voz en vivo por red local (WiFi/hotspot)
- Grupo multi-rider
- Canal privado (susurro 1 a 1)
- Botón de emergencia
- Push-to-talk y manos libres
- Compatible iPhone y Android
