# MotoBridge Android

App Android nativa (Kotlin + Jetpack Compose) que implementa el **modo Universal** del bridge de audio de MotoBridge, para interoperar con la app iOS (ver [`../PROTOCOL.md`](../PROTOCOL.md)).

## Qué hace
- Descubre y se conecta con un iPhone (en modo Universal) por **red local** (mDNS/NSD + UDP).
- Captura el micrófono y reproduce el audio del otro extremo (8 kHz mono PCM16, con AEC/NS).
- Push-to-talk, medidor de nivel de micrófono y ganancias, equivalentes a la app iOS.

## Requisitos
- Android Studio (Ladybug o más reciente).
- JDK 17.
- Un dispositivo Android físico (el micrófono no funciona bien en emulador).

## Abrir y compilar
1. En Android Studio: **File → Open** y selecciona la carpeta `android/`.
2. Android Studio descargará dependencias y **generará el Gradle wrapper** automáticamente. Si pide sincronizar, acepta (**Sync Now**).
3. Conecta un Android físico con **depuración USB** activada.
4. Pulsa **Run ▶**.
5. Al abrir, concede el permiso de **micrófono**.

> Alternativa por terminal (si ya tienes el wrapper): `./gradlew installDebug`

## Probar con el iPhone
1. Pon el Android y el iPhone en la **misma red WiFi** (o el hotspot de uno).
2. En el iPhone: MotoBridge → selecciona **modo Universal (Android)** → **INICIAR BRIDGE**.
3. En el Android: **INICIAR BRIDGE** → concede micrófono.
4. Se descubren y conectan solos. Mantén **PUSH TO TALK** y habla.

⚠️ Usa audífonos en al menos un lado para evitar eco, o sepáralos.

## Estructura
```
android/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle.properties
└── app/
    ├── build.gradle.kts
    └── src/main/
        ├── AndroidManifest.xml
        ├── res/values/themes.xml
        └── java/com/motobridge/android/
            ├── MainActivity.kt          (UI Compose + permiso mic)
            ├── BridgeController.kt       (une audio + red)
            ├── audio/AudioIO.kt          (AudioRecord/AudioTrack 8kHz + AEC/NS)
            └── net/
                ├── MotoBridgePacket.kt   (protocolo neutral, = iOS)
                └── LocalNetworkTransport.kt (NSD + UDP)
```

## Nota de verificación
