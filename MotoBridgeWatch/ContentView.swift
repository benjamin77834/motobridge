import SwiftUI

private enum Overlay { case confirmAlarm, confirmStop }

struct ContentView: View {
    @EnvironmentObject private var model: WatchRemoteModel
    @State private var overlay: Overlay?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !model.reachable {
                    Text("iPhone no alcanzable")
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                        .foregroundStyle(.black)
                        .accessibilityLabel("iPhone no alcanzable")
                }
                TabView {
                    ControlPage(overlay: $overlay)
                    StatusPage()
                    BridgePage(overlay: $overlay)
                }
                .tabViewStyle(.verticalPage)
            }
            if let overlay {
                overlayView(overlay)
            }
            alarmResult
        }
        .onChange(of: model.reachable) { _, reachable in
            if !reachable { overlay = nil }
        }
    }

    @ViewBuilder
    private func overlayView(_ o: Overlay) -> some View {
        Group {
            switch o {
            case .confirmAlarm:
                ConfirmView(title: "¿Enviar alarma a todo el grupo?", confirmLabel: "ENVIAR ALARMA", tint: .red,
                            onConfirm: { overlay = nil; model.sendAlarm() },
                            onCancel: { overlay = nil })
            case .confirmStop:
                ConfirmView(title: "¿Detener el bridge? Se corta el audio del grupo", confirmLabel: "DETENER", tint: .red,
                            onConfirm: { overlay = nil; model.stopBridge() },
                            onCancel: { overlay = nil })
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder
    private var alarmResult: some View {
        switch model.alarmOp {
        case .pending:
            ProgressOverlay(text: "Enviando…")
        case .done:
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle)
                Text("Alarma enviada").font(.headline.weight(.heavy))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.red)
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
        case .failed(let reason):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title)
                Text("NO SE ENVIÓ").font(.headline.weight(.heavy))
                Text(reason).font(.caption).multilineTextAlignment(.center)
                Button("Reintentar") { model.sendAlarm() }
                    .tint(.red)
                    .frame(minHeight: 44)
                Button("Cerrar") { model.dismissAlarmResult() }
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        case .idle:
            EmptyView()
        }
    }
}

private struct ProgressOverlay: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text(text).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Páginas

private struct ControlPage: View {
    @EnvironmentObject private var model: WatchRemoteModel
    @Binding var overlay: Overlay?

    private var running: Bool { model.state?.running == true }
    private var micOpen: Bool { model.state?.mic == true }
    private var controlsEnabled: Bool { model.reachable && model.controlOp != .pending && model.state != nil }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                model.setMic(!micOpen)
            } label: {
                HStack(spacing: 4) {
                    if model.controlOp == .pending {
                        Text("…")
                    } else {
                        Image(systemName: micOpen ? "mic.fill" : "mic.slash")
                        Text(!model.reachable || model.state == nil ? "MICRÓFONO —"
                             : micOpen ? "MICRÓFONO ABIERTO" : "MICRÓFONO CERRADO")
                            .font(.caption.weight(.bold))
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(micOpen ? .green : .gray)
            .buttonStyle(.borderedProminent)
            .disabled(!controlsEnabled || (!running && !micOpen))
            .accessibilityLabel(micOpen ? "Micrófono abierto. Toca para cerrar" : "Micrófono cerrado. Toca para abrir")

            Button {
                overlay = .confirmAlarm
            } label: {
                Label("ALARMA", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline.weight(.heavy))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .disabled(!model.reachable || !running || model.alarmOp == .pending)
            .accessibilityLabel("Alarma de emergencia")

            if model.reachable, model.state != nil, !running {
                Text("Bridge detenido").font(.caption2).foregroundStyle(.secondary)
            } else if case .failed(let reason) = model.controlOp {
                Text(reason).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
    }
}

private struct StatusPage: View {
    @EnvironmentObject private var model: WatchRemoteModel

    var body: some View {
        let live = model.reachable ? model.state : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if live?.alarm == true {
                    Text("ALARMA ACTIVA")
                        .font(.caption.weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .padding(4)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 6))
                }
                if model.refreshing { Text("Actualizando…").font(.caption2).foregroundStyle(.secondary) }
                Text(live.map { $0.running ? "Bridge activo" : "Bridge detenido" } ?? "Bridge —")
                    .font(.headline)
                Text(live.map { $0.mic ? "Micrófono abierto" : "Micrófono cerrado" } ?? "Micrófono —")
                    .font(.footnote)
                Text(live.map { "\($0.peerCount) riders conectados" } ?? "— riders conectados")
                    .font(.footnote)
                if let live {
                    ForEach(Array(live.peers.enumerated()), id: \.offset) { _, name in
                        Text("• \(name)").font(.caption).lineLimit(1)
                    }
                    if live.peerCount > live.peers.count {
                        Text("+\(live.peerCount - live.peers.count) más").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BridgePage: View {
    @EnvironmentObject private var model: WatchRemoteModel
    @Binding var overlay: Overlay?

    private var running: Bool { model.state?.running == true }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                if running { overlay = .confirmStop } else { model.startBridge() }
            } label: {
                Text(running ? "Detener bridge" : "Iniciar bridge")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(running ? .red : .green)
            .buttonStyle(.borderedProminent)
            .disabled(!model.reachable || model.state == nil || model.controlOp == .pending)
            .accessibilityLabel(running ? "Detener bridge" : "Iniciar bridge")

            if model.controlOp == .pending {
                ProgressView()
            } else if case .failed(let reason) = model.controlOp {
                Text(reason).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else if model.reachable, let s = model.state, !s.running, !s.canStart {
                Text("Para iniciar, abre Mono Bridge en el iPhone").font(.caption2)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

#Preview("Sin enlace") {
    ContentView().environmentObject(WatchRemoteModel())
}
