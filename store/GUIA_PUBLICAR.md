# Guía para publicar Mono Bridge en Google Play

## Archivos listos (carpeta store/ y build)
- **App Bundle (subir a Play):** `android/app/build/outputs/bundle/release/app-release.aab`
- **Ícono 512×512:** `store/play_icon_512.png`
- **Gráfico destacado 1024×500:** `store/play_feature_1024x500.png`
- **Capturas:** `store/screenshot1.png`, `store/screenshot2.png` (sube 2 o más)
- **Textos de la ficha:** `store/LISTING.md`
- **Política de privacidad:** `store/PRIVACY_POLICY.md`

## Datos de firma (GUARDAR, irrecuperables)
- Keystore: `android/keystore/monobridge-release.jks`
- storePassword / keyAlias / keyPassword: `MonoBridge2026` / `monobridge` / `MonoBridge2026`
- applicationId: `com.monkeyphone.monobridge`

---

## Paso a paso

### 1. Crear cuenta de Google Play Console
- Entra a https://play.google.com/console
- Regístrate como desarrollador. **Costo único: $25 USD.**
- Verifica tu identidad (documento oficial). Puede tardar 1-2 días.
- Elige cuenta **Personal** o **Organización**. Para vender, ambas sirven.

### 2. Configurar pagos (para vender)
- En Play Console: **Configuración → Perfil de pagos.**
- Crea un perfil de pagos (datos fiscales + cuenta bancaria para recibir ingresos).
- Sin esto no puedes cobrar por la app.

### 3. Alojar la política de privacidad
- Sube el texto de `PRIVACY_POLICY.md` a una URL pública.
- Opciones gratis: Google Sites, GitHub Pages, Notion público, o una página en tu web.
- Guarda esa URL, la pedirán en la ficha.

### 4. Crear la app en Play Console
- **Crear app** → nombre "Mono Bridge", idioma español, tipo "App", **De pago**.

### 5. Subir el App Bundle
- Menú **Producción → Crear nueva versión.**
- Sube `app-release.aab`.
- Google gestiona la firma final (App Signing) automáticamente; acepta.

### 6. Completar la ficha de Play Store
- Descripción corta y larga: copia de `LISTING.md`.
- Ícono: `play_icon_512.png`.
- Gráfico destacado: `play_feature_1024x500.png`.
- Capturas: `screenshot1.png`, `screenshot2.png` (mínimo 2).
- Categoría: Comunicación.
- Correo de soporte + URL de política de privacidad.

### 7. Cuestionarios obligatorios
- **Clasificación de contenido:** responde el cuestionario (la app es apta para todos).
- **Seguridad de los datos:** declara que usas micrófono para transmisión en vivo y que NO recopilas ni almacenas datos (según PRIVACY_POLICY).
- **Permisos:** justifica el micrófono (intercom de voz) y la red local.
- **App de anuncios:** No.
- **Público objetivo:** mayores de 13 (no dirigida a niños).

### 8. Precio
- **Monetización → Precios.** Fija el precio (ej. $2.99 USD) y los países.

### 9. Pruebas requeridas (cuentas personales nuevas)
- Google puede exigir **prueba cerrada con 12 testers durante 14 días** antes de permitir producción, si tu cuenta es personal creada después de nov-2023.
- Crea una **prueba cerrada**, invita 12 correos (amigos), que instalen y usen la app 14 días.
- Después se habilita el botón para enviar a **Producción**.

### 10. Enviar a revisión
- Revisa que todo esté en verde y envía. La revisión de Google tarda de horas a varios días.

---

## Avisos importantes (honestos)
- **Micrófono:** Google revisa con cuidado apps que graban/usan micrófono. Ten clara la justificación (intercom de voz en vivo, sin grabar). Puede que pidan un video demostrativo.
- **Comisión de Google:** 15% sobre los primeros $1,000,000 USD/año de ingresos, 30% después.
- **iOS es aparte:** esta guía es solo para Google Play (Android). Publicar en la App Store de Apple requiere cuenta de Apple Developer ($99 USD/año) y otro proceso.
- **No cambies** el applicationId ni pierdas el keystore: sin ellos no podrás actualizar la app.
