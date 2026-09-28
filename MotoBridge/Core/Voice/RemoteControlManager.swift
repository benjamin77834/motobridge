import Foundation
import MediaPlayer
import UIKit

/// Lee los botones multimedia que envían por Bluetooth los intercomunicadores
/// (Hysnox, FreedConn, etc.) usando MPRemoteCommandCenter. iOS entrega los
/// botones AVRCP del casco como comandos de control remoto:
///
///   - play / pause / togglePlayPause  → botón central (multifunción)
///   - nextTrack                       → botón siguiente (▶▶)
///   - previousTrack                   → botón anterior (◀◀)
///
/// OJO: no todos los botones del intercom llegan a iOS. Los botones propios del
/// firmware (emparejar, FM, teléfono, "intercom" nativo) NO se exponen. Solo
/// los de transporte multimedia estándar. El mapeo exacto depende del hardware
/// y se confirma probando en el dispositivo real.
final class RemoteControlManager {

    /// Botón central (play/pause/toggle): pensado para hablar (PTT toggle).
    var onTogglePressed: (() -> Void)?
    /// Botón siguiente (▶▶).
    var onNextPressed: (() -> Void)?
    /// Botón anterior (◀◀).
    var onPreviousPressed: (() -> Void)?

    private let center = MPRemoteCommandCenter.shared()
    private var registered = false

    /// Activa la recepción de comandos de control remoto.
    func start() {
        guard !registered else { return }
        registered = true

        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onTogglePressed?(); return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.onTogglePressed?(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onTogglePressed?(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextPressed?(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousPressed?(); return .success
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    /// Desactiva la recepción (al detener el bridge).
    func stop() {
        guard registered else { return }
        registered = false
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }
}
