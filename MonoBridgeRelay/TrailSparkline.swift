import SwiftUI

/// Mini-gráfica del RASTRO de una persona: cómo ha cambiado su proximidad con
/// el tiempo. Línea que sube = se acerca; baja = se aleja. Da el histórico, no
/// solo el estado actual, para que en un rescate se vea la tendencia.
struct TrailSparkline: View {
    let trail: [Double]          // valores 0..1 (1 = más cerca)
    var color: Color = .green

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if trail.count >= 2 {
                let maxX = Double(trail.count - 1)
                Path { p in
                    for (i, v) in trail.enumerated() {
                        let x = CGFloat(Double(i) / maxX) * w
                        let y = h - CGFloat(max(0, min(1, v))) * h
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                // Punto al final (posición actual).
                let lastX = w
                let lastY = h - CGFloat(max(0, min(1, trail.last!))) * h
                Circle().fill(color).frame(width: 4, height: 4)
                    .position(x: lastX - 2, y: lastY)
            } else {
                Rectangle().fill(Color.gray.opacity(0.15))
            }
        }
    }
}
