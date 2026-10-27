import SwiftUI

/// Radar visual tipo "pantalla de radar": círculos concéntricos (cercanía por
/// saltos de malla) con cada nodo como un punto. Al centro está la Mac (este
/// nodo). Verde = cerca, amarillo = lejos, rojo = sin señal. Muestra el nombre,
/// la diferencia de pisos/altura (Modo Rescate) y la batería de cada rider.
struct RadarView: View {
    @EnvironmentObject private var relay: RelaySession

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxR = size / 2 - 20

            ZStack {
                // Anillos concéntricos (3 niveles de cercanía).
                ForEach(1...3, id: \.self) { ring in
                    Circle()
                        .stroke(Color.green.opacity(0.18), lineWidth: 1)
                        .frame(width: maxR * 2 * CGFloat(ring) / 3,
                               height: maxR * 2 * CGFloat(ring) / 3)
                        .position(center)
                }
                // Cruz central.
                Path { p in
                    p.move(to: CGPoint(x: center.x - maxR, y: center.y))
                    p.addLine(to: CGPoint(x: center.x + maxR, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: center.y - maxR))
                    p.addLine(to: CGPoint(x: center.x, y: center.y + maxR))
                }
                .stroke(Color.green.opacity(0.12), lineWidth: 1)

                // Nodo central = este Mac.
                VStack(spacing: 2) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 18)).foregroundStyle(.green)
                    Text("Relay").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .position(center)

                // Riders/nodos como puntos alrededor.
                ForEach(Array(relay.riders.enumerated()), id: \.element.id) { idx, node in
                    nodeDot(node: node, index: idx, total: relay.riders.count,
                            center: center, maxR: maxR)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func nodeDot(node: RelaySession.RiderNode, index: Int, total: Int,
                         center: CGPoint, maxR: CGFloat) -> some View {
        // Radio según cercanía (hops): cerca = anillo interior.
        let ringFraction: CGFloat = {
            switch node.level {
            case .near: return 0.34
            case .far:  return 0.68
            case .lost: return 1.0
            }
        }()
        // Ángulo repartido en círculo para que no se encimen.
        let angle = (Double(index) / Double(max(total, 1))) * 2 * .pi - .pi / 2
        let r = maxR * ringFraction
        let pos = CGPoint(x: center.x + r * CGFloat(cos(angle)),
                          y: center.y + r * CGFloat(sin(angle)))
        VStack(spacing: 2) {
            Circle()
                .fill(color(node.level))
                .frame(width: 14, height: 14)
                .shadow(color: color(node.level).opacity(0.8), radius: 4)
            Text(node.name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            if let line = detailLine(node) {
                Text(line).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96)
        .position(pos)
    }

    /// Texto con pisos/altura (Modo Rescate) y batería, si llegan.
    private func detailLine(_ node: RelaySession.RiderNode) -> String? {
        var parts: [String] = []
        if let m = relay.metersDelta(for: node) {
            let am = abs(m)
            if am < 1 { parts.append("mismo nivel") }
            else {
                let dir = m > 0 ? "↑" : "↓"
                let floors = relay.floors(for: node) ?? 0
                let f = abs(floors)
                parts.append(f == 0 ? "\(dir)\(Int(am))m" : "\(dir)\(Int(am))m · \(f)p")
            }
        }
        if let b = node.batteryPercent { parts.append("🔋\(b)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private func color(_ l: RelaySession.RiderNode.Level) -> Color {
        switch l { case .near: return .green; case .far: return .yellow; case .lost: return .red }
    }
}
