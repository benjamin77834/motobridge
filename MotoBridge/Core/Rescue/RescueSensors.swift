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
