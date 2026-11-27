# Requisitos: unique-rider-name
Nombre único del rider. Casi todos los iPhone se llaman "iPhone" (`UIDevice.name`). Con nombres iguales falla la regla "nombre menor inicia" del canal UDP/Universal, los mensajes privados dirigidos por nombre (hash FNV-1a: ambos reciben), el radar y el pickup. iOS no permite leer el número de serie; se usa el `deviceUID` estable de la app.
## Glosario
- Nombre automático: `iPhone-XXXX`, `iPad-XXXX`, `Mac-XXXX`, `Android-XXXX`. XXXX son 4 caracteres alfanuméricos en mayúsculas del UID propio de la app (iOS y Mac: `deviceUID`; Android: ANDROID_ID o un UUID guardado).
- Nombre propio: el que el usuario escribió y se guardó (`riderName`; en Mac `relayName`).
- Nombre efectivo: nombre propio si existe, si no el automático; con sufijo del UID si hubo colisión.
## Requisitos
### R1. Nombre efectivo
1. Sin nombre propio, el nombre efectivo es el automático.
2. Con nombre propio, ese es el efectivo (recortado a 30 caracteres, sin espacios en los extremos).
3. El nombre efectivo se usa en Multipeer (`MCPeerID`), Bonjour/UDP, presencia, mensajes privados e id por nombre, pickup, radar, el reloj (que recibe los nombres del iPhone) y Mac Relay.
4. Dos dispositivos con UID distinto tienen nombres automáticos distintos (salvo 1 de cada 65 536 por coincidencia de los 4 caracteres, que cae en R2).
### R2. Colisión
1. Si el dispositivo ve a otro peer con su mismo nombre efectivo, guarda una marca de colisión y añade el sufijo del UID (`Ben-3F9A`). Un nombre automático que colisiona pasa a 8 caracteres (`iPhone-3F9A1C22`).
2. El sufijo no se añade dos veces.
3. Multipeer no permite cambiar el `MCPeerID` en caliente: el nombre nuevo se aplica al detener el bridge (siguiente inicio). Está documentado en la interfaz ("Se aplicará al detener el bridge").
4. Guardar un nombre nuevo borra la marca de colisión.
### R3. Pregunta de primer arranque (decidido: SÍ)
1. Si no hay nombre propio guardado, al abrir la app se muestra "¿Cuál es tu nombre?" con el automático sugerido (editable). Android: diálogo. Mac Relay: campo "Mi nombre" con aviso.
2. Guardar un nombre lo conserva y no se vuelve a preguntar. Un nombre guardado por una versión anterior cuenta como propio: no se pregunta.
3. Si se omite, se usa el automático y se recuerda una vez más al iniciar el bridge. Máximo 2 apariciones en total (contador `riderNamePromptCount`), cuenten como cuenten (omitir o cerrar).
4. La pregunta no bloquea el audio: el bridge arranca sin esperar la respuesta. Un nombre guardado con el bridge en marcha se aplica al detenerlo.
5. Sigue editable en Ajustes ("Mi nombre"), incluso con el bridge en marcha.
### R4. Compatibilidad
1. El formato en el cable no cambia (el nombre sigue siendo la primera línea de presencia y el nombre de instancia Bonjour).
2. Las apps anteriores siguen anunciando "iPhone"; con ellas los nombres pueden repetirse y el problema persiste. No se rompe el enlace en la transición. Actualizar todas las apps del grupo lo resuelve. Declarado en `PROTOCOL.md`.
### R5. Restricciones
1. Sin permisos nuevos (Android usa ANDROID_ID).
2. No se toca `PERFORMANCE_MODE_LOW_LATENCY`, la tolerancia de 30 s, ni el número de build.
