import SwiftUI

/// Botón grande de push-to-talk en la muñeca. Mantén presionado para hablar.
/// El audio pasa por el iPhone; el Watch solo manda el comando.
struct WatchPTTView: View {
    @StateObject private var client = WatchConnectivityClient()
    @State private var transmitting = false

    var body: some View {
        VStack(spacing: 8) {
            // Indicador de estado del bridge en el iPhone.
            HStack(spacing: 6) {
                Circle()
                    .fill(client.bridgeConnected ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(client.bridgeConnected ? "Conectado" : "Sin bridge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Botón PTT grande.
            ZStack {
                Circle()
                    .fill(transmitting ? Color.green : Color.blue.opacity(0.85))
                Text(transmitting ? "HABLANDO" : "HABLAR")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !transmitting {
                            transmitting = true
                            client.sendPTT(true)
                        }
                    }
                    .onEnded { _ in
                        transmitting = false
                        client.sendPTT(false)
                    }
            )
        }
        .padding(6)
    }
}

#Preview {
    WatchPTTView()
}
