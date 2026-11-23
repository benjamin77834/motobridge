# Requisitos: hotspot-rider-guide

## Objetivo

Dar al rider una guía dentro de la app para que su hotspot sea lo más estable posible en carretera, con el paso "Maximizar compatibilidad" en iPhone y su equivalente en Android, sin prometer un alcance concreto. Aplica a iOS, Android y Mac Relay.

## Dependencias

Ninguna. Es independiente y puede publicarse en cualquier momento (riesgo bajo). Si se publica antes del spec 5, el texto no menciona iOS 26.

## Origen y supuestos

- Entrada: estudio §1 (hecho adicional sobre hotspot) y spec 6; decisión del usuario 6 (topología con hotspot cuando exista).
- Hecho verificado: "Maximizar compatibilidad" existe en iPhone 12 o posterior ([Apple Platform Security](https://support.apple.com/en-lamr/guide/security/secfd166f620/web)).
- Hecho con fuente no oficial: que esa opción fuerza la banda de 2,4 GHz lo dicen la comunidad de Apple ([Apple Community 256014511](https://discussions.apple.com/thread/256014511)) y sitios de terceros, no una página oficial de soporte.
- Hecho físico general, no una medición de Apple: 2,4 GHz suele llegar más lejos y atravesar mejor obstáculos que 5 GHz, con menos velocidad y más interferencia. No se promete ninguna distancia.
- Hecho del código: `PROTOCOL.md` §7 ya advierte de hotspots con aislamiento de clientes que bloquean UDP entre dispositivos.
- Hecho del código: no hay texto sobre el tema en la app hoy.
- Supuesto A1: el idioma de la app es español; no hay catálogo de localización (no se encontró `.xcstrings` ni `.strings` en `MotoBridge/`). Los textos se escriben en español y en Android en `res/values/strings.xml`.
- Supuesto A2: los pasos para Android varían por fabricante y versión. Se redactan para Samsung One UI (el usuario usa Samsung S25) y de forma genérica para otros, marcados como "pueden variar".

## Requisitos funcionales (EARS)

### R1. Acceso a la guía

CUANDO el usuario abra la ayuda de conexión o el apartado de conexión de la pantalla del bridge, EL SISTEMA DEBERÁ ofrecer una entrada llamada "Maximizar compatibilidad (hotspot)" que abra la guía.

Criterios de aceptación:
1. R1.1 En iOS la entrada es accesible desde `NetworkBridgeView.swift` en no más de 2 toques desde la pantalla principal del bridge.
2. R1.2 En Android la entrada es accesible desde `MainActivity.kt` en no más de 2 toques.
3. R1.3 En Mac Relay la guía aparece como sección de ayuda en la ventana principal.
4. R1.4 La guía se puede abrir sin estar conectado a ningún rider y sin red.

### R2. Contenido para iPhone

EL SISTEMA DEBERÁ mostrar los pasos para activar "Maximizar compatibilidad" en el hotspot de iPhone.

Criterios de aceptación:
1. R2.1 Los pasos mencionan Ajustes, Punto de acceso personal y el interruptor "Maximizar compatibilidad", y el requisito de iPhone 12 o posterior.
2. R2.2 Indica que el cambio puede ser necesario cuando algún dispositivo no ve la red o la conexión es inestable.
3. R2.3 Explica en una frase que la opción usa la banda de 2,4 GHz, que suele llegar más lejos pero es más lenta y más sensible a interferencias.
4. R2.4 No contiene ninguna distancia, velocidad ni porcentaje de mejora.
5. R2.5 Declara que el alcance depende de obstáculos, interferencias y los dispositivos, y que no se garantiza ninguno.

### R3. Contenido para Android

EL SISTEMA DEBERÁ mostrar los pasos para configurar la banda de 2,4 GHz en el hotspot de Android.

Criterios de aceptación:
1. R3.1 Incluye los pasos de Samsung One UI (Ajustes, Conexiones, Punto de acceso móvil y anclaje, Punto de acceso móvil, Configurar, Banda) y una línea genérica para otros fabricantes que indica que los nombres pueden variar.
2. R3.2 Los pasos se validan en un Samsung S25 con el Android actual antes de publicar (tarea 2).
3. R3.3 Aplica las mismas reglas de no prometer alcance (R2.4 y R2.5).

### R4. Aviso de aislamiento de clientes y causas comunes

EL SISTEMA DEBERÁ avisar de que algunos hotspots impiden la comunicación directa entre dispositivos y qué hacer.

Criterios de aceptación:
1. R4.1 El texto explica que, si los dispositivos se ven en la red pero no hay audio, puede deberse al aislamiento de clientes del hotspot, y sugiere probar otro hotspot (por ejemplo el de otro rider) o el modo con conexión directa entre iPhones.
2. R4.2 El texto indica que todos los riders deben estar en la misma red Wi-Fi o hotspot para incluir a Android y Mac (hoy así lo dice `TransportMode.explanation`).

### R5. Honestidad y mantenimiento del contenido

Criterios de aceptación:
1. R5.1 Una revisión del texto confirma que no hay frases con "garantiza", "hasta X metros", "mejora el alcance en X %".
2. R5.2 La nota de fuente (opción de 2,4 GHz según soporte de comunidad, no de Apple) queda en el diseño y en el archivo de contenido como comentario para el equipo, no en la pantalla del rider.
3. R5.3 El texto de la guía vive en un solo archivo por plataforma y se revisa cuando cambie la versión de iOS o Android objetivo.

### R6. Accesibilidad básica

Criterios de aceptación:
1. R6.1 La guía respeta el tamaño de texto dinámico del sistema en iOS y Android.
2. R6.2 Cada paso tiene etiqueta de accesibilidad (VoiceOver y TalkBack) con el mismo texto visible.
3. R6.3 La guía es legible con la app en uso de día y de noche (tema existente), sin colores nuevos.

## Fuera de alcance

- Detectar la banda del hotspot (iOS no la expone).
- Medir o prometer alcance.
- Activar el hotspot o cambiar su configuración desde la app.
- Traducción a otros idiomas (no hay infraestructura de localización).
- Tutorial en vídeo.
