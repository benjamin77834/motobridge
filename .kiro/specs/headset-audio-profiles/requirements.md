# Requisitos: headset-audio-profiles
Perfil de audio por audífono. Alcance de esta pasada: solo iOS. Android queda pendiente (ver tareas).
## Glosario
- Perfil: volumen de escucha propio de la app (`speakerGain`), filtro de ruido (`gateThreshold`), mejora de voz (`voiceEnhancementEnabled`) y ganancia de captura (`micGain`).
- Audífono activo: primer puerto no integrado de la ruta actual (entradas, luego salidas).
## Requisitos
### R1. Identificación
1. El sistema identifica el audífono por nombre de puerto (sin mayúsculas ni espacios en los extremos) más la familia de conexión (bluetooth, cableado, USB, otro).
2. Los puertos integrados del teléfono (micrófono, receptor, altavoz) no tienen perfil.
3. El mismo audífono tiene la misma clave en A2DP y en HFP.
4. iOS no da un identificador único por audífono: dos cascos del mismo modelo y nombre comparten perfil. Está documentado en la interfaz y en design.md.
### R2. Aplicar
1. Cuando cambia la ruta o se refrescan las entradas y existe un perfil guardado del audífono activo, el sistema lo aplica.
2. La primera vez que se ve un audífono, parte de los valores por defecto actuales según calidad (los de `refreshInputs`: AirPods/Beats alta, estándar, intercom HFP baja; Ray-Ban Meta con escucha 3.0).
3. Al cambiar a un audífono sin perfil se restauran sus valores por defecto, para que los ajustes del casco anterior no se arrastren.
### R3. Guardar
1. Cuando el usuario ajusta alguno de los cuatro valores con un audífono activo, el perfil se guarda de inmediato en UserDefaults.
2. Los cambios hechos por la app (valores por defecto, aplicar un perfil, subida automática de Ray-Ban) no se guardan.
### R4. Interfaz
1. La pantalla de audio muestra el nombre del audífono activo y si su perfil está guardado o usa valores por defecto.
2. Un botón restablece el perfil del audífono activo (borra el guardado y vuelve a los valores por defecto). Está deshabilitado si no hay perfil guardado.
3. Hay un interruptor de mejora de voz.
### R5. Restricciones
1. No se cambia el volumen del sistema.
2. No se toca el modo intercom automático (`scheduleIntercomMode`, `applyIntercomMode`).
