import Foundation
import CoreMotion
import CoreLocation

/// Sensores del teléfono para el MODO RESCATE (localizar a una persona atrapada
/// sin GPS: terremoto, derrumbe, cueva).
///
/// - Altímetro barométrico (CMAltimeter): da la altura RELATIVA en metros desde
///   que arranca. Comparando la altura de la víctima con la del rescatista se
///   estima la diferencia de PISOS (≈3 m por piso). Funciona bajo tierra o entre
///   escombros, porque no depende de satélites.
/// - Brújula (CLLocationManager heading): el rumbo magnético al que apunta el
///   teléfono. No apunta a la víctima por sí sola; sirve para que el rescatista
///   anote en qué rumbo SUBE la señal (RSSI) mientras gira.
///
/// Honestidad de precisión:
/// - El barómetro deriva lentamente con el clima; en el lapso de un rescate la
///   deriva es pequeña, pero NO es una altitud absoluta sobre el nivel del mar.
/// - La brújula se distorsiona con metal/escombros. Es orientación aproximada.
final class RescueSensors: NSObject, ObservableObject {

    /// Metros por piso para convertir altura barométrica en "pisos".
    static let metersPerFloor: Double = 3.0

    /// Altura relativa en metros desde que empezó a medir (nil si no hay sensor
    /// o aún no llega la primera muestra).
    @Published private(set) var relativeAltitudeMeters: Double?

    /// Presión barométrica en kPa (diagnóstico).
    @Published private(set) var pressureKPa: Double?

    /// Rumbo magnético del teléfono en grados (0 = Norte). nil si no disponible.
    @Published private(set) var headingDegrees: Double?

    /// Detector de rumbo "caliente/frío": mientras el rescatista gira, se guarda
    /// la fuerza de señal recibida en cada sector de brújula. `bestBearing` es el
    /// rumbo (grados) donde la señal fue MÁS FUERTE = hacia dónde conviene ir.
    /// nil hasta tener muestras. NO es una flecha exacta a la persona (sin GPS no
    /// existe), es la dirección en la que la señal mejora.
    @Published private(set) var bestBearing: Double?
    @Published private(set) var bestBearingStrength: Float = 0
    /// Señal por sector de 30° (12 sectores). Se desvanece con el tiempo para
    /// que el rescatista pueda re-barrer y la medición no quede "pegada".
    private var sectorStrength = [Float](repeating: 0, count: 12)
    private var sectorTime = [Date](repeating: .distantPast, count: 12)

    /// Alimenta el detector con una muestra de señal entrante (0–1), asociándola
    /// al rumbo actual de la brújula. Llamar cuando llega voz del otro.
    func noteSignalSample(_ level: Float) {
        guard let h = headingDegrees, level > 0.01 else { return }
        let sector = Int((h / 30.0).rounded(.down)) % 12
        // Quedarse con el pico reciente de cada sector (decae con el tiempo).
        if level >= sectorStrength[sector] {
            sectorStrength[sector] = level
            sectorTime[sector] = Date()
        }
        recomputeBest()
    }

    private func recomputeBest() {
        var bestIdx = -1
        var best: Float = 0
        let now = Date()
        for i in 0..<12 {
            // Desvanecer muestras viejas (>12 s) para permitir re-barrido.
            let age = now.timeIntervalSince(sectorTime[i])
            let decayed = age > 12 ? 0 : sectorStrength[i] * Float(max(0, 1 - age / 12))
            if decayed > best { best = decayed; bestIdx = i }
        }
        if bestIdx >= 0 {
            bestBearing = Double(bestIdx) * 30 + 15  // centro del sector
            bestBearingStrength = best
        } else {
            bestBearing = nil
            bestBearingStrength = 0
        }
    }

    /// ¿El dispositivo tiene altímetro barométrico? (iPhone 6s+ casi todos).
    let hasBarometer: Bool = CMAltimeter.isRelativeAltitudeAvailable()

    private let altimeter = CMAltimeter()
    private let locationManager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Arranca la lectura de altímetro y brújula.
    func start() {
        guard !running else { return }
        running = true

        if hasBarometer {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.relativeAltitudeMeters = data.relativeAltitude.doubleValue
                self.pressureKPa = data.pressure.doubleValue
            }
        }

        // La brújula no necesita permiso de ubicación "siempre"; con when-in-use
        // basta. Pedimos autorización por si el usuario aún no la dio.
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if CLLocationManager.headingAvailable() {
            locationManager.headingFilter = 2 // grados
            locationManager.startUpdatingHeading()
        }
    }

    /// Detiene las lecturas y libera los sensores.
    func stop() {
        guard running else { return }
        running = false
        altimeter.stopRelativeAltitudeUpdates()
        locationManager.stopUpdatingHeading()
        relativeAltitudeMeters = nil
        pressureKPa = nil
        headingDegrees = nil
        bestBearing = nil
        bestBearingStrength = 0
        sectorStrength = [Float](repeating: 0, count: 12)
        sectorTime = [Date](repeating: .distantPast, count: 12)
    }

    /// Convierte una diferencia de altura (metros) a número de pisos con signo.
    /// Positivo = la otra persona está ARRIBA; negativo = ABAJO.
    static func floorsFrom(metersDelta: Double) -> Int {
        return Int((metersDelta / metersPerFloor).rounded())
    }
}

extension RescueSensors: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Preferir el rumbo verdadero si está disponible; si no, el magnético.
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        if value >= 0 { headingDegrees = value }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }
}
