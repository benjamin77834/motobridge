import Foundation

/// Nombre efectivo del rider. Casi todos los iPhone se llaman "iPhone"
/// (UIDevice.name), lo que rompe la regla "nombre menor inicia", los mensajes
/// privados por hash de nombre y el radar. Esta lógica pura (sin UIKit, la usan
/// iOS y Mac Relay) produce un nombre único: el elegido por el usuario o, por
/// defecto, "<Equipo>-XXXX" con XXXX derivado del UID estable de la app.
/// Spec: .kiro/specs/unique-rider-name.
enum RiderName {
    /// MCPeerID.displayName admite hasta 63 bytes UTF-8; se deja margen.
    static let maxLength = 60
    /// Largo del nombre que escribe el usuario (igual que antes).
    static let maxCustomLength = 30
    static let collisionKey = "riderNameCollision"

    /// 4 caracteres alfanuméricos en mayúsculas derivados del UID.
    static func suffix(uid: String, length: Int = 4) -> String {
        let chars = uid.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let s = String(chars.prefix(length))
        return s.count == length ? s : s + String(repeating: "0", count: length - s.count)
    }

    /// Nombre automático: "iPhone-3F9A".
    static func automatic(prefix: String, uid: String) -> String {
        "\(prefix)-\(suffix(uid: uid))"
    }

    /// Limpia lo escrito por el usuario: recorta espacios y largo.
    static func sanitize(_ raw: String) -> String {
        String(String(raw.prefix(maxCustomLength)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Nombre con el que se anuncia este rider.
    /// - saved: nombre elegido (vacío o nil = no hay).
    /// - collision: se detectó otro peer con el mismo nombre; se añade sufijo del UID.
    static func effective(saved: String?, prefix: String, uid: String, collision: Bool) -> String {
        let custom = sanitize(saved ?? "")
        let sfx = suffix(uid: uid)
        var name: String
        if custom.isEmpty {
            name = collision ? "\(prefix)-\(suffix(uid: uid, length: 8))" : automatic(prefix: prefix, uid: uid)
        } else {
            name = (collision && !custom.hasSuffix("-\(sfx)")) ? "\(custom)-\(sfx)" : custom
        }
        return String(name.prefix(maxLength))
    }

    /// ¿Algún otro peer lleva mi mismo nombre?
    static func collides(local: String, peers: [String]) -> Bool {
        peers.contains(local)
    }

    /// Lee nombre guardado y marca de colisión de `defaults` y calcula el efectivo.
    static func current(defaults: UserDefaults = .standard, savedKey: String = "riderName",
                        prefix: String, uid: String) -> String {
        effective(saved: defaults.string(forKey: savedKey), prefix: prefix, uid: uid,
                  collision: defaults.bool(forKey: collisionKey))
    }
}

/// Cuándo pedir "¿Cuál es tu nombre?". Se pide solo si el usuario no tiene un
/// nombre propio guardado, como máximo 2 veces en total (al abrir la app y un
/// recordatorio al iniciar el bridge). Nunca bloquea el audio.
struct RiderNamePromptPolicy {
    enum Trigger { case appOpen, bridgeStart }
    static let maxPrompts = 2
    static let countKey = "riderNamePromptCount"

    let defaults: UserDefaults
    let savedKey: String

    init(defaults: UserDefaults = .standard, savedKey: String = "riderName") {
        self.defaults = defaults
        self.savedKey = savedKey
    }

    var hasOwnName: Bool {
        !RiderName.sanitize(defaults.string(forKey: savedKey) ?? "").isEmpty
    }
    var promptCount: Int { defaults.integer(forKey: Self.countKey) }

    func shouldPrompt(_ trigger: Trigger) -> Bool {
        guard !hasOwnName, promptCount < Self.maxPrompts else { return false }
        switch trigger {
        case .appOpen: return promptCount == 0
        case .bridgeStart: return true
        }
    }

    /// Llamar al mostrar la pantalla: cuenta contra el máximo aunque se omita.
    func markShown() { defaults.set(promptCount + 1, forKey: Self.countKey) }

    /// Guarda el nombre elegido. Vacío = omitido (no guarda). Devuelve si guardó.
    @discardableResult
    func save(_ name: String) -> Bool {
        let clean = RiderName.sanitize(name)
        guard !clean.isEmpty else { return false }
        defaults.set(clean, forKey: savedKey)
        return true
    }
}
