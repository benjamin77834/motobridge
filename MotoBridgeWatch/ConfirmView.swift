import SwiftUI
import Combine

/// Confirmación a pantalla completa con cuenta atrás de 5 s; al agotarse se
/// cancela sola sin enviar nada.
struct ConfirmView: View {
    let title: String
    let confirmLabel: String
    let tint: Color
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var remaining = 5
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button(action: onConfirm) {
                Text(confirmLabel).font(.headline.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(tint)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(confirmLabel)
            Button(action: onCancel) {
                Text("Cancelar (\(remaining)s)").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Cancelar")
        }
        .onReceive(ticker) { _ in
            remaining -= 1
            if remaining <= 0 { onCancel() }
        }
    }
}

#Preview("Confirmar alarma") {
    ConfirmView(title: "¿Enviar alarma a todo el grupo?", confirmLabel: "ENVIAR ALARMA",
                tint: .red, onConfirm: {}, onCancel: {})
}
