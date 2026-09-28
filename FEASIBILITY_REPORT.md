# FEASIBILITY_REPORT.md — MotoBridge

**Fase:** FASE 0 — Factibilidad
**Fecha:** 2026-09-16
**Objetivo evaluado:** FreedConn T-COM VB ↔ iPhone ↔ Hysnox (puente de audio bidireccional entre dos intercomunicadores Bluetooth de moto usando el iPhone como puente)
**Alcance:** Solo APIs públicas de Apple (CoreBluetooth, AVFoundation, AVAudioSession, AVAudioEngine). Sin APIs privadas.

---

## 0. Conclusión ejecutiva

### 🔴 RED — para el diseño original (bridge de audio Bluetooth↔Bluetooth simultáneo con dos intercomunicadores)

**El iPhone NO puede, mediante APIs públicas de iOS, tomar audio de un intercomunicador Bluetooth de moto y enviarlo simultáneamente a otro intercomunicador Bluetooth de moto.**

Esto se debe a **tres limitaciones acumulativas e independientes** de iOS, no a un problema de implementación:

1. **CoreBluetooth NO da acceso al audio Bluetooth Classic (HFP/A2DP).** Los intercomunicadores de moto usan Bluetooth Classic para voz, y ese audio es gestionado por el sistema operativo, no por la app.
2. **iOS enruta el audio de una sesión a UNA sola ruta de entrada y (para voz/HFP) UNA sola de salida.** No existe una API pública para tener dos dispositivos Bluetooth de audio activos como entrada+salida simultáneas de una comunicación de voz.
3. **iOS no permite entrada HFP desde un Bluetooth + salida hacia otro Bluetooth** dentro de la misma sesión de audio. Está documentado explícitamente por Apple.

El proyecto NO debe continuar a implementar el bridge Bluetooth↔Bluetooth. Debe detenerse esa vía y adoptar la **arquitectura alternativa** descrita en la sección 7.

> Nota importante de honestidad técnica: esta conclusión se basa en documentación pública de Apple y comportamiento conocido y consistente de iOS. La regla fundamental del proyecto (#24) exige *"no decir funciona hasta haber probado en un iPhone real"*. Aquí aplicamos el corolario simétrico: la evidencia de las APIs públicas indica que **NO es viable**, y la app de diagnóstico de la FASE 3 servirá para **confirmar experimentalmente** este RED en el hardware concreto del usuario antes de descartar definitivamente cualquier matiz.

---

## 1. Cómo funcionan realmente los intercomunicadores de moto (FreedConn / Hysnox)

Los intercomunicadores de motocicleta como **FreedConn T-COM VB** y **Hysnox** son, desde el punto de vista del iPhone, **auriculares/manos-libres Bluetooth Classic**. Exponen fundamentalmente:

- **HFP / HSP** (Hands-Free / Headset Profile): audio de voz bidireccional, mono, baja calidad (típicamente 8 kHz o 16 kHz mSBC). Es el perfil que se usa en llamadas.
- **A2DP** (Advanced Audio Distribution Profile): audio estéreo de alta calidad **solo salida** (música). No lleva micrófono.
- **AVRCP**: control de reproducción (play/pausa/volumen). No es audio.

El "intercom" real entre dos cascos de la misma marca ocurre por un **protocolo propietario de Bluetooth Classic entre los dos dispositivos**, que **el iPhone no ve ni puede intermediar** (y la regla #18 prohíbe hacer ingeniería inversa de ese protocolo).

**Consecuencia:** para el iPhone, cada intercom es "un headset Bluetooth de llamada". El problema se reduce a: *¿puede iOS usar dos headsets Bluetooth a la vez, uno como micrófono-in y otro como altavoz-out, y viceversa?*

---

## 2. CoreBluetooth — qué puede y qué NO puede

### Qué SÍ puede CoreBluetooth
- Descubrir, conectar e intercambiar datos con dispositivos **Bluetooth Low Energy (BLE / GATT)**.
- Leer servicios y características GATT, RSSI, estado de conexión de periféricos **BLE**.
- Actuar como central o como periférico BLE.

### Qué NO puede CoreBluetooth
- **NO** puede descubrir ni enumerar dispositivos **Bluetooth Classic** (los intercoms de moto).
- **NO** da acceso a los perfiles de audio Bluetooth Classic (**HFP, HSP, A2DP**). Esos perfiles los gestiona el sistema.
- **NO** puede leer/escribir el stream de audio de un headset.
- **NO** puede acceder a dispositivos Bluetooth Classic a menos que sean **MFi certificados** y la app declare el protocolo correspondiente (vía External Accessory framework, no CoreBluetooth). Los intercoms genéricos de moto **no son MFi**.

> Evidencia: los foros de Apple confirman que las apps no pueden escanear ni acceder a dispositivos Bluetooth Classic salvo que sean MFi y la app incluya el protocolo correspondiente; CoreBluetooth está limitado a BLE. HFP/A2DP son Bluetooth Classic y BLE no puede detectar perfiles Classic.
> _Contenido reformulado por cumplimiento de licencias._
> Fuentes: [Apple Developer Forums — iOS App to connect to classic bluetooth](https://developer.apple.com/forums/thread/769197), [SO — classic bluetooth on iOS requires MFi](https://stackoverflow.com/questions/76001851/), [SO — CoreBluetooth and audio stream restrictions](https://stackoverflow.com/questions/12185145/corebluetooth-and-audio-stream).

**Diferenciación exigida por el proyecto (sección 5):**

| Capa | ¿La ve/controla la app? | Framework | Nota |
|---|---|---|---|
| Bluetooth Classic (dispositivo) | ❌ No (salvo MFi) | External Accessory (solo MFi) | Los intercoms no son MFi |
| Bluetooth LE (GATT) | ✅ Sí | CoreBluetooth | Los intercoms de moto no exponen su audio por aquí |
| Perfiles de audio BT (HFP/A2DP) | ⚠️ Solo indirectamente | AVAudioSession (como "ruta") | La app ve la *ruta*, no el stream ni el dispositivo Classic |

**Conclusión CoreBluetooth:** solo servirá para mostrar dispositivos **BLE** cercanos y, si el intercom expone alguna característica BLE (poco probable para audio), leerla. **No sirve para el bridge de audio.** La detección de que el intercom está "conectado" para audio se hará vía `AVAudioSession.currentRoute` / `availableInputs`, NO vía CoreBluetooth.

---

## 3. AVAudioSession — reglas de enrutamiento reales

### 3.1 Un solo input, salida única para voz
Para categorías de grabación/voz (`record`, `playAndRecord`), iOS aplica una **regla de "último conectado" (last-in)** para elegir el input, y expone un **único input activo** a la vez. No hay API pública para tener dos entradas Bluetooth simultáneas de voz.

> Evidencia: Apple documenta para MultiRoute que se soportan *un único input y múltiples outputs*, con regla last-in para el input.
> _Contenido reformulado por cumplimiento de licencias._
> Fuente: [Apple Developer Forums — How do you use the MultiRoute session](https://developer.apple.com/forums/thread/12710).

### 3.2 No se puede: input HFP de un BT + output hacia otro BT
Apple confirma explícitamente que **no se puede sacar audio por A2DP mientras se recibe input por HFP**. Y más recientemente, que **no soportan input HFP + otra salida** simultáneamente en configuraciones tipo LiveListen.

> Evidencia: *"no puedes reproducir vía A2DP mientras aceptas input vía HFP"* y *"no soportamos actualmente input HFP + salida por altavoz"*.
> _Contenido reformulado por cumplimiento de licencias._
> Fuentes: [Apple Developer Forums — Bluetooth with PlayAndRecord](https://forums.developer.apple.com/forums/thread/4340), [Apple Developer Forums — Bluetooth mic in, live listen out](https://developer.apple.com/forums/thread/829728).

### 3.3 Opciones de categoría Bluetooth (aclaración crítica)
- `.allowBluetooth` → habilita **HFP** (voz bidireccional mono, baja calidad). Requiere categoría `record` o `playAndRecord`.
- `.allowBluetoothA2DP` → habilita **A2DP** (salida estéreo alta calidad, **sin** micrófono simultáneo por ese dispositivo).

> Evidencia: `.allowBluetooth` significa en la práctica "preferir HFP" y permite in+out con un dispositivo BT pero con baja calidad; `.allowBluetoothA2DP` da salida de alta calidad pero **no** soporta input simultáneo.
> _Contenido reformulado por cumplimiento de licencias._
> Fuentes: [SO — primary audio output AVAudioSession](https://stackoverflow.com/questions/73218863/), [SO — AVAudioSession not working on certain BT devices](https://stackoverflow.com/questions/50789276/).

**Punto clave:** aunque tengas dos intercoms "conectados" en Ajustes, cuando activas una sesión de voz iOS **selecciona uno** como ruta HFP. No hay API pública para asignar *intercom A = input* y *intercom B = output* de una comunicación de voz.

### 3.4 ¿Y la categoría `multiRoute`?
`multiRoute` está pensada para combinaciones de rutas **cableadas/USB/altavoz** (p. ej. USB + auriculares), **no** para dos dispositivos **Bluetooth** de audio, y **no** admite AirPlay. No hay evidencia ni soporte documentado de dos rutas Bluetooth Classic simultáneas de voz vía `multiRoute`.

---

## 4. AVAudioEngine — capacidad de proceso (no es el cuello de botella)

`AVAudioEngine` **sí** puede: capturar del `inputNode`, procesar (mezcla, ganancia, filtros) y reproducir por el `outputNode`, con taps para medir latencia. El procesamiento local no es el problema.

**El problema es el enrutamiento físico previo:** `AVAudioEngine` toma su `inputNode` de la **ruta activa** que decide `AVAudioSession`, y saca por la **ruta de salida activa**. No puede "elegir" que la entrada venga del intercom A y la salida vaya al intercom B si iOS no permite esa combinación de rutas. Es decir, AVAudioEngine hereda las limitaciones de la sección 3.

---

## 5. Tabla de resultados FASE 0

| Pregunta de la FASE 0 | Resultado | Detalle |
|---|---|---|
| ¿iOS puede tener conectados a la vez FreedConn + Hysnox? | 🟡 PARCIAL | Ambos pueden estar *emparejados/conectados* en Ajustes, pero solo uno es **ruta de audio activa** de voz a la vez. |
| ¿Pueden usarse como input/output de audio simultáneamente (uno in, otro out)? | 🔴 NO | iOS no expone API pública para input BT-A + output BT-B en una sesión de voz. |
| ¿Puede AVAudioSession seleccionar las rutas necesarias? | 🔴 NO | Regla last-in: un solo input; HFP-in + otra-out no soportado. |
| ¿Puede AVAudioEngine procesar el audio? | 🟢 SÍ | El proceso local funciona; el límite está en el enrutamiento (sección 3/4). |
| ¿Existe limitación de Bluetooth Classic? | 🔴 SÍ | CoreBluetooth no accede a Classic/HFP/A2DP; requeriría MFi (los intercoms no lo son). |

---

## 6. Qué SÍ es viable con APIs públicas (para no bloquear el producto)

- 🟢 Mostrar estado de rutas de audio: `AVAudioSession.currentRoute`, `availableInputs`, tipos de puerto (`bluetoothHFP`, `bluetoothA2DP`), sample rate, canales.
- 🟢 Detectar cambios de ruta e interrupciones (notificaciones `routeChange`, `interruption`).
- 🟢 Descubrir dispositivos **BLE** con CoreBluetooth (informativo, RSSI, servicios).
- 🟢 Captura de micrófono + reproducción a **una** ruta con `AVAudioEngine` (mono, baja latencia, PTT clásico contra **un** dispositivo).
- 🟢 Un flujo tipo "walkie-talkie de una vía por vez" contra el dispositivo que esté como ruta HFP activa.
- 🟢 Logging/diagnóstico completo de todo lo anterior.

Esto permite cumplir varios criterios de éxito (#1, #2, #3, #4, #8, #9, #10) aunque el criterio #5 (bridge BT↔BT simultáneo) quede como **NO POSIBLE** vía Bluetooth directo.

---

## 7. Arquitectura alternativa propuesta (obligada por la regla #24)

Dado el RED del bridge Bluetooth↔Bluetooth directo, se proponen alternativas, en orden de recomendación:

### Alternativa A — Bridge por Internet / Red local (recomendada, ya prevista en sección 20)
```
Intercom A (HFP) → iPhone #1 → [Internet / Wi-Fi / MultipeerConnectivity] → iPhone #2 → Intercom B (HFP)
```
- Cada iPhone habla con **un solo** intercom vía HFP (soportado).
- El puente ocurre entre **dos teléfonos** por red (Network framework / MultipeerConnectivity / WebRTC).
- ✅ Totalmente viable con APIs públicas. Es el patrón real de apps de comunicación de moto (tipo intercom por app).
- ⚠️ Requiere **dos** iPhones (uno por piloto), no uno solo puenteando dos cascos.

### Alternativa B — Un iPhone + un intercom por PTT half-duplex
- Un solo iPhone contra un solo intercom (ruta HFP activa), modo walkie-talkie.
- No es el bridge original, pero es 100% viable y útil como MVP.

### Alternativa C — MFi / External Accessory
- Solo si se usara hardware **MFi certificado** con protocolo declarado. Los FreedConn/Hysnox actuales no lo son → **descartada** para este hardware.

**Recomendación:** adoptar **Alternativa A** como diseño objetivo del bridge real, y **Alternativa B** como MVP inmediato. El resto de la app (dashboard, diagnostics, permisos, logging, arquitectura de dispositivos) se mantiene sin cambios.

---

## 8. Impacto en las fases siguientes

- **FASE 1 (proyecto base):** sin cambios. Se puede proceder.
- **FASE 2 (Bluetooth):** ajustar expectativa — la "detección" de intercoms será vía `AVAudioSession` (rutas HFP/A2DP), y BLE solo informativo. No prometer detección de dispositivos Classic por CoreBluetooth.
- **FASE 3 (Audio Diagnostics):** **prioritaria** — servirá para *confirmar experimentalmente en el iPhone real del usuario* este informe (mostrar que solo hay una ruta HFP activa a la vez).
- **FASE 4 (Audio Bridge BT↔BT):** **CANCELADA** en su forma original. Se reemplaza por el bridge por red (Alternativa A) en una fase posterior.
- **FASE 5 (PTT):** viable contra un dispositivo (Alternativa B).

---

## 9. Veredicto por componente

| Componente | Veredicto |
|---|---|
| Detección de estado de dispositivos de audio | 🟢 GREEN |
| Diagnóstico de rutas de audio (AVAudioSession) | 🟢 GREEN |
| Captura/reproducción local (AVAudioEngine) | 🟢 GREEN |
| Descubrimiento BLE (CoreBluetooth) | 🟢 GREEN (informativo) |
| Acceso a audio Bluetooth Classic vía CoreBluetooth | 🔴 RED |
| **Bridge de audio simultáneo BT↔BT en un solo iPhone** | 🔴 **RED** |
| Bridge por Internet / red local entre 2 iPhones | 🟢 GREEN (fase futura) |

---

## 10. Referencias

- [Apple Developer Forums — Bluetooth with AVAudioSession PlayAndRecord (HFP vs A2DP)](https://forums.developer.apple.com/forums/thread/4340)
- [Apple Developer Forums — Bluetooth mic in, live listen out (HFP input + output no soportado)](https://developer.apple.com/forums/thread/829728)
- [Apple Developer Forums — How do you use the MultiRoute session (single input, last-in)](https://developer.apple.com/forums/thread/12710)
- [Apple Developer Forums — iOS App to connect to classic bluetooth (MFi / External Accessory)](https://developer.apple.com/forums/thread/769197)
- [Stack Overflow — Classic Bluetooth en iOS requiere MFi](https://stackoverflow.com/questions/76001851/)
- [Stack Overflow — CoreBluetooth y restricciones de audio stream](https://stackoverflow.com/questions/12185145/corebluetooth-and-audio-stream)
- [Stack Overflow — allowBluetooth (HFP) vs allowBluetoothA2DP](https://stackoverflow.com/questions/73218863/)
- [Stack Overflow — playAndRecord + A2DP output desde iOS 10](https://stackoverflow.com/questions/50789276/)

_Todo el contenido citado de fuentes externas fue reformulado y resumido por cumplimiento de restricciones de licencia. Verificación final pendiente de prueba en hardware real (FASE 3), conforme a la regla #24._
