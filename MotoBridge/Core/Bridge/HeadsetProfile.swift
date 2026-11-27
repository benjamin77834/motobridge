import Foundation
import AVFoundation

/// Ajustes de audio que se recuerdan por audífono.
struct HeadsetProfile: Codable, Equatable {
    var speakerGain: Float
    var gateThreshold: Float
    var voiceEnhancement: Bool
    var micGain: Float
}

/// Identidad de un audífono: nombre de puerto normalizado + familia de conexión.
/// iOS no expone un identificador único por audífono, así que dos cascos del
/// mismo modelo y nombre comparten perfil. La familia (no el tipo exacto de
/// puerto) evita que los AirPods tengan un perfil en A2DP y otro en HFP.
enum HeadsetIdentity {
    /// Clave estable, o nil para los puertos integrados del teléfono (sin perfil).
    static func key(portName: String, portType: String) -> String? {
        let name = portName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, let family = family(of: portType) else { return nil }
        return "\(name)|\(family)"
    }

    static func family(of portType: String) -> String? {
        switch portType {
        case AVAudioSession.Port.builtInMic.rawValue,
             AVAudioSession.Port.builtInReceiver.rawValue,
             AVAudioSession.Port.builtInSpeaker.rawValue:
            return nil
        case AVAudioSession.Port.bluetoothA2DP.rawValue,
             AVAudioSession.Port.bluetoothHFP.rawValue,
             AVAudioSession.Port.bluetoothLE.rawValue:
            return "bluetooth"
        case AVAudioSession.Port.headsetMic.rawValue,
             AVAudioSession.Port.headphones.rawValue:
            return "wired"
        case AVAudioSession.Port.usbAudio.rawValue:
            return "usb"
        default:
            return "other"
        }
    }
}

/// Persistencia de perfiles en UserDefaults (un diccionario JSON por clave).
final class HeadsetProfileStore {
    static let defaultsKey = "headsetProfiles"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func load() -> [String: HeadsetProfile] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let dict = try? JSONDecoder().decode([String: HeadsetProfile].self, from: data) else { return [:] }
        return dict
    }

    private func store(_ dict: [String: HeadsetProfile]) {
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func profile(for key: String) -> HeadsetProfile? { load()[key] }

    func save(_ profile: HeadsetProfile, for key: String) {
        var dict = load()
        dict[key] = profile
        store(dict)
    }

    func remove(_ key: String) {
        var dict = load()
        dict[key] = nil
        store(dict)
    }
}
