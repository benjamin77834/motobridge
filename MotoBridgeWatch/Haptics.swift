import WatchKit

/// Envoltorio mínimo de la háptica del reloj.
enum Haptics {
    static func success() { WKInterfaceDevice.current().play(.success) }
    static func failure() { WKInterfaceDevice.current().play(.failure) }
    static func click() { WKInterfaceDevice.current().play(.click) }
}
