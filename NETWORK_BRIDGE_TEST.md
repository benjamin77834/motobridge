# Prueba del Network Bridge (iPhone ↔ iPad)

Guía para probar el prototipo de **bridge de audio en vivo por red local** (MultipeerConnectivity). Valida el corazón de la Alternativa A del `FEASIBILITY_REPORT`: audio bidireccional entre dos dispositivos Apple sin depender de una red concreta ni de internet.

## Qué valida esta prueba
- Descubrimiento automático entre dos dispositivos (sin configurar red).
- Conexión peer-to-peer (funciona en mismo WiFi, hotspot o sin red).
- Captura de micrófono + transmisión + reproducción en el otro dispositivo.
- Push-to-talk.

> Nota: esta prueba **no** usa intercomunicadores todavía. Usa el micrófono/altavoz del dispositivo (o AirPods). En moto, cada teléfono se conectaría a su intercom por HFP; el transporte de red es el mismo.

## Requisitos
- Xcode 26+ y un Apple ID (una cuenta gratuita sirve para instalar en tus propios dispositivos).
- iPhone y iPad con cable o confianza establecida.
- Recomendado: audífonos en al menos uno de los dos (ver "Eco" abajo).

## Instalar en ambos dispositivos

1. Genera y abre el proyecto:
   ```bash
   xcodegen generate
   open MotoBridge.xcodeproj
   ```
2. En Xcode, selecciona el target **MotoBridge** → pestaña **Signing & Capabilities** → elige tu **Team** (Apple ID). Xcode asignará un bundle id firmable.
3. Conecta el **iPhone**, selecciónalo como destino y pulsa **Run** (⌘R). Acepta en el teléfono "confiar en este desarrollador" si lo pide (Ajustes → General → VPN y gestión de dispositivos).
4. Repite con el **iPad** como destino y **Run**.

Ahora ambos tienen la app instalada.

## Ejecutar la prueba

1. Pon los dos dispositivos en la **misma red** (mismo WiFi o el hotspot de uno). Si no hay red, igual funciona: MultipeerConnectivity crea una red directa.
2. Abre MotoBridge en los dos → toca **Network Bridge**.
3. En ambos, toca **INICIAR BRIDGE**.
   - La primera vez, iOS pedirá permiso de **red local** y de **micrófono**: acepta ambos.
4. En unos segundos, cada dispositivo debería mostrar al otro en "Dispositivos cercanos" y pasar a **Conectado** (se conectan automáticamente).
5. Mantén presionado **PUSH TO TALK** en el iPhone y habla → deberías oírte en el iPad. Suelta y prueba al revés desde el iPad.
6. Observa las **métricas**: "Paquetes enviados" sube en el que transmite; "Paquetes recibidos" sube en el que escucha.

## Eco / acople (importante)
Si los dos dispositivos están cerca **sin audífonos**, el micrófono de uno captará el altavoz del otro y habrá eco o pitido. Es normal, no es un bug. Para una prueba limpia:
- Usa audífonos en al menos un dispositivo, **o**
- Sepáralos varios metros, **o**
- Usa el push-to-talk de forma alternada (solo uno transmite a la vez).

## Resultado esperado
- ✅ Se descubren y conectan solos.
- ✅ Voz audible del uno al otro con latencia baja (décimas de segundo).
- ⚠️ Calidad de voz mono 16 kHz (suficiente para intercom, no HiFi).

## Si algo falla
- **No se ven entre sí:** confirma que ambos tienen el bridge iniciado y aceptaron el permiso de red local. Prueba a acercarlos. En hotspot con "aislamiento de clientes" activo, MultipeerConnectivity suele caer a WiFi directo o Bluetooth igualmente; deja pasar unos segundos.
- **No hay permiso de red local:** Ajustes → MotoBridge → activa "Red local".
- **No hay audio:** verifica el permiso de micrófono (Ajustes → MotoBridge → Micrófono) y sube el volumen.
- Revisa los logs en **Settings → Diagnostics** (categoría "Bridge").

## Limitaciones conocidas de este prototipo
- Sin cancelación de eco propia (se apoya en push-to-talk / audífonos).
- Formato mono 16 kHz fijo.
- Aún no integra los intercoms; eso es el siguiente paso una vez validado el transporte.
