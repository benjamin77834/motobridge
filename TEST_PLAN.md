# TEST_PLAN.md — MotoBridge

## 1. Tests automatizados (actuales)

Ejecutar:
```bash
xcodebuild -project MotoBridge.xcodeproj -scheme MotoBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test
```

Cobertura actual (7 tests, todos pasan):
- **AudioBridgeTests**: estado inicial `idle`; `prepare()` reporta la limitación de iOS; `stop()` vuelve a `idle`.
- **DeviceTests**: identidad de FreedConn/Hysnox; capacidades (no MFi); actualización de estado desde ruta de audio.
- **LoggerTests**: el export contiene cabecera.

Pendiente (fases siguientes, sección 22): tests de `AudioSessionManager` (mock de rutas), integración de settings y de diagnóstico.

## 2. Verificación manual en simulador (FASE 1 + 3)
- [x] La app compila y arranca.
- [ ] Dashboard muestra las tarjetas y navegación a Diagnostics/Settings.
- [ ] Audio Diagnostics: "Iniciar / Refrescar" puebla categoría, sample rate, canales, ruta actual.
- [ ] Export de diagnóstico abre el share sheet.

> Nota: el simulador no expone Bluetooth; el veredicto de rutas mostrará "ruta BT única/no evaluado". Esto es esperado.

## 3. Prueba en hardware real (FASE 7 — pendiente)
Con iPhone físico + FreedConn T-COM VB + Hysnox + casco:
- [ ] Conectar ambos intercoms en Ajustes de iOS.
- [ ] Abrir Audio Diagnostics y registrar: input/output/available, sample rate, canales, y el **veredicto experimental** de rutas simultáneas.
- [ ] Confirmar (o refutar) que iOS solo expone una ruta HFP activa a la vez → valida L1/FEASIBILITY_REPORT.
- [ ] Cambiar de ruta (encender/apagar un intercom) y verificar que `routeChange` se registra.
- [ ] Provocar una interrupción (llamada entrante) y verificar el manejo.
- [ ] Exportar diagnóstico y adjuntarlo al informe.

## 4. Criterios de aceptación de esta fase
- [x] Proyecto compila en Xcode (BUILD SUCCEEDED).
- [x] Tests unitarios pasan.
- [x] La app no simula capacidades inexistentes (bridge reporta la limitación).
- [x] Arquitectura modular y extensible.
