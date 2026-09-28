# ARCHITECTURE.md — MotoBridge

**Versión:** 0.1.0 (FASE 1 + FASE 3)

## Principios

1. **Separación en capas:** UI (Features) ↔ orquestación (Services) ↔ lógica/hardware (Core) ↔ datos (Models).
2. **Honestidad técnica:** ningún componente simula capacidades que iOS no ofrece (ver `FEASIBILITY_REPORT.md`). Donde iOS impone un límite, la app lo refleja explícitamente.
3. **Extensibilidad (sección 19):** los dispositivos se modelan tras el protocolo `IntercomDevice` para añadir Cardo/Sena/etc. sin acoplar la UI a un fabricante.

## Capas

### Models
- `IntercomDevice` (protocolo): identidad + estado + capacidades opcionales. No asume que toda capacidad esté disponible.
- Enums: `ConnectionState`, `Manufacturer`, `DeviceCapabilities`.

### Core
- **Audio / `AudioSessionManager`**: única puerta a `AVAudioSession`. Configura categoría de voz (`playAndRecord`/`voiceChat`/HFP), activa/desactiva, publica un `AudioRouteSnapshot` (inputs/outputs/available/sample rate/canales), y escucha `routeChangeNotification` e `interruptionNotification`. Calcula el **veredicto experimental** de rutas Bluetooth simultáneas a partir de los puertos reales.
- **Devices / `BaseIntercomDevice` + `FreedConnDevice` + `HysnoxDevice`**: adaptadores/identificadores. En iOS el audio Bluetooth Classic lo gestiona el sistema, así que el estado "conectado" se deriva de la ruta activa de `AVAudioSession`, no de un canal que la app controle.
- **Bridge / `AudioBridge`**: máquina de estados (`idle/initializing/ready/bridging/paused/error`). `prepare()` reporta la limitación de iOS (bridge BT↔BT no viable) en lugar de fingir un estado listo.
- **Diagnostics / `Logger`**: singleton `ObservableObject`, niveles DEBUG/INFO/WARNING/ERROR, buffer acotado (2000), export a archivo.
- **Bluetooth**: reservado para FASE 2 (descubrimiento BLE informativo).

### Services
- `AppState`: `ObservableObject` raíz inyectado en el entorno SwiftUI. Crea managers y dispositivos, y sincroniza el estado de los dispositivos con la ruta de audio (match por nombre de puerto).

### Features (SwiftUI, dark mode, botones grandes, alto contraste)
- `DashboardView`: pantalla principal.
- `AudioDiagnosticsView`: FASE 3.
- `SettingsView` + `LogView`.
- `PushToTalk`: reservado para FASE 5.

## Flujo de datos

```
AVAudioSession (iOS)
   │ notificaciones (routeChange / interruption)
   ▼
AudioSessionManager  ──publica──▶ AudioRouteSnapshot / verdict
   │                                   │
   │ (Combine)                         ▼
   ▼                              AudioDiagnosticsView
AppState ──sincroniza──▶ FreedConnDevice / HysnoxDevice ──▶ DashboardView
```

## Diseño objetivo del bridge (fase futura)

Dado el RED del bridge BT↔BT directo, el bridge real será **por red** (Alternativa A del FEASIBILITY_REPORT):

```
Intercom A (HFP) → iPhone #1 → [Network framework / Multipeer / WebRTC] → iPhone #2 → Intercom B (HFP)
```

Cada iPhone habla con **un solo** intercom vía HFP (soportado). La capa de red se añadirá sin tocar `Models`/`Core/Devices`.
