# Diseño: hotspot-rider-guide

## Visión general

Es una función de solo texto y navegación: una pantalla de ayuda estática en iOS, Android y Mac Relay, abierta desde la pantalla del bridge. No hay red, ni nuevas capacidades de protocolo, ni lógica de detección. El diseño se reduce a dónde vive el contenido, cómo se abre y qué se afirma.

**Stack:** SwiftUI en iOS y Mac Relay, la UI actual de `MainActivity.kt` en Android (la tarea 1 confirma si es Jetpack Compose o vistas XML). Sin dependencias nuevas. Funciona con el mínimo actual de cada plataforma, también antes del spec 5.

## Decisión 1: pantalla estática, no detección automática

**Elegido:** contenido estático.

Alternativas descartadas:
- *Detectar la banda del hotspot y avisar*: iOS no expone la banda ni la intensidad Wi-Fi (foro de Apple 721067). En Android se puede leer la frecuencia de la red propia, pero no la del hotspot de otro rider. Se descarta por cobertura desigual.
- *Abrir directamente Ajustes en el hotspot*: iOS no permite abrir pantallas de Ajustes que no sean las de la propia app de forma soportada. Se descarta.
- *Una página web externa*: la guía no estaría disponible sin red en carretera.

## Decisión 2: dónde vive el contenido

- iOS: una vista SwiftUI `HotspotGuideView.swift` en `MotoBridge/Features/PushToTalk/` junto a `NetworkBridgeView.swift`, con el texto en una estructura de datos (lista de pasos y notas) en el mismo archivo, para revisarlo en un solo lugar (R5.3).
- Android: cadenas en `android/app/src/main/res/values/strings.xml` y la pantalla o diálogo desde `MainActivity.kt`.
- Mac: sección de ayuda en la ventana principal del Relay (`RelayApp.swift`), reutilizando el mismo texto de iOS. El archivo de texto no se comparte entre targets para no tocar `project.yml`; se copia y se anota en comentarios que debe mantenerse igual.

Alternativa descartada: *un archivo de contenido común (JSON) para las tres plataformas*. Hay 4 párrafos; el costo de un mecanismo compartido supera su beneficio.

## Decisión 3: redacción (propuesta, el usuario la valida en la tarea 1)

Título: "Maximizar compatibilidad (hotspot)".

Pasos para iPhone (12 o posterior):
1. Abre Ajustes y entra en Punto de acceso personal.
2. Activa "Maximizar compatibilidad".
3. Vuelve a conectar los demás dispositivos a la red del iPhone.

Qué significa: "Esta opción hace que el hotspot use la banda de 2,4 GHz. Esa banda suele llegar más lejos y atravesar mejor los obstáculos, pero es más lenta y más sensible a interferencias. El alcance real depende del entorno y de los dispositivos; no se puede garantizar ninguna distancia."

Pasos para Android (Samsung One UI, otros fabricantes pueden variar): Ajustes, Conexiones, Punto de acceso móvil y anclaje, Punto de acceso móvil, Configurar, Banda de la red Wi-Fi: elegir 2,4 GHz.

Si hay red pero no hay audio: "Algunos hotspots impiden que los dispositivos se hablen entre sí (aislamiento de clientes). Prueba con el hotspot de otro rider, o usa la conexión directa entre iPhones."

**Nota de fuente (solo para el equipo):** que "Maximizar compatibilidad" fuerza 2,4 GHz está respaldado por la comunidad de Apple y sitios de terceros, no por una página oficial de soporte. La afirmación sobre alcance es física general. Por eso el texto no promete cifras.

## Decisión 4: punto de entrada

- iOS: botón "Ayuda de hotspot" cerca del selector de modo en `NetworkBridgeView.swift`; abre `HotspotGuideView` como hoja (`sheet`).
- Android: ítem en la pantalla principal que abre un diálogo o pantalla con scroll.
- Mac: sección plegable de ayuda en la ventana.

Alternativa descartada: *mostrar la guía automáticamente al fallar la conexión*. Sin una señal fiable de "falló por el hotspot" se mostraría fuera de contexto. Se deja en backlog para cuando exista la métrica de calidad del spec 4.

## Archivos a modificar

- iOS: nuevo `HotspotGuideView.swift`; `NetworkBridgeView.swift` (botón).
- Android: `strings.xml`, `MainActivity.kt` (entrada y pantalla).
- Mac: `RelayApp.swift` (sección de ayuda).
- Docs: `README.md` (breve mención) y página de la tienda solo si el usuario lo pide.

## Manejo de errores

No hay operaciones que puedan fallar en tiempo de ejecución distintas de la presentación de una vista. Si la hoja o el diálogo no se pueden presentar (por ejemplo, otra hoja ya está abierta), el toque no hace nada y no se registra. No hay validación de entrada: la función no recibe datos externos.

## Invariantes

- **Ninguna frase promete alcance.** La aplica la revisión de texto (R5.1) y una búsqueda automática de palabras prohibidas en los archivos de contenido durante la tarea de revisión. Se aplica en esa capa porque no hay lógica donde forzarlo.

## Testabilidad

- Pruebas de interfaz (UI test) solo si ya existen en el proyecto; si no, verificación manual de acceso (R1) en iPhone, Android y Mac.
- Prueba automatizada sencilla: un test unitario por plataforma que busca en el texto las palabras "garantiza", "metros", "%" y falla si aparecen.
- La validación de los pasos de Android requiere un Samsung S25 físico.
