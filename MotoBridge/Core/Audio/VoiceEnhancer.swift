import Foundation

/// Realce de voz para señales de banda estrecha (8 kHz de HFP, como el Hysnox).
///
/// No convierte 8 kHz en HD (imposible, la información no está), pero mejora la
/// inteligibilidad y reduce el carácter "radio AM":
///  1. Paso-alto (~120 Hz): quita retumbe/viento/motor.
///  2. Realce de presencia (pico ~2 kHz): destaca las consonantes de la voz.
///  3. Normalización suave: nivela el volumen sin bombear.
///
/// Trabaja sobre buffers Int16 mono in-place. Los coeficientes se recalculan si
/// cambia el sample rate.
final class VoiceEnhancer {

    private var sampleRate: Double = 0

    // Filtro paso-banda de voz: paso-alto 300 Hz + paso-bajo 3400 Hz.
    private var hp = BiquadState()      // paso-alto 300 Hz (corta graves/música/motor)
    private var lp = BiquadState()      // paso-bajo 3400 Hz (corta agudos/platillos)
    private var peak = BiquadState()    // realce de presencia ~2 kHz

    // Normalización (seguimiento de envolvente).
    private var envelope: Float = 0

    // Noise gate: si el nivel de voz está por debajo del umbral, silencia.
    /// Umbral del gate (0..1). Ajustable. Sube para cortar más ruido de fondo.
    var gateThreshold: Float = 0.015
    private var gateEnv: Float = 0
    private var gateGain: Float = 0   // 0 = cerrado, 1 = abierto (con suavizado)

    struct BiquadState {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0

        mutating func process(_ x: Float) -> Float {
            // Forma directa transpuesta II.
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// (Re)configura los filtros para un sample rate dado.
    func configure(sampleRate: Double) {
        guard sampleRate > 0, sampleRate != self.sampleRate else { return }
        self.sampleRate = sampleRate
        // Banda de voz telefónica: 300–3400 Hz. Fuera de ahí, la música (graves
        // y agudos) se atenúa fuertemente.
        hp = makeHighpass(freq: 300, sampleRate: sampleRate)
        // El paso-bajo solo tiene sentido si Nyquist lo permite (sr/2 > 3400).
        let lpFreq = min(3400.0, sampleRate / 2 - 200)
        lp = makeLowpass(freq: lpFreq, sampleRate: sampleRate)
        peak = makePeaking(freq: 2000, q: 1.0, gainDB: 5.0, sampleRate: sampleRate)
        envelope = 0
        gateEnv = 0
        gateGain = 0
    }

    /// Procesa un buffer Int16 mono in-place.
    func process(_ samples: UnsafeMutablePointer<Int16>, count: Int, sampleRate: Double) {
        configure(sampleRate: sampleRate)
        guard self.sampleRate > 0 else { return }

        for i in 0..<count {
            var s = Float(samples[i]) / 32768.0

            // 1) Filtro paso-banda de voz: paso-alto 300 Hz + paso-bajo 3400 Hz.
            //    Recorta graves y agudos de la música/ruido fuera de la voz.
            s = hp.process(s)
            s = lp.process(s)
            // 2) Realce de presencia.
            s = peak.process(s)

            // 3) Noise gate: mide la energía de la señal YA filtrada (solo banda
            //    de voz). Si está por debajo del umbral, cierra el micrófono con
            //    suavizado para no cortar bruscamente.
            let mag = abs(s)
            let gCoeff: Float = mag > gateEnv ? 0.5 : 0.05
            gateEnv += (mag - gateEnv) * gCoeff
            let targetGate: Float = gateEnv > gateThreshold ? 1.0 : 0.0
            // Suavizado del gate (ataque rápido al abrir, cierre algo más lento).
            let smooth: Float = targetGate > gateGain ? 0.3 : 0.08
            gateGain += (targetGate - gateGain) * smooth
            s *= gateGain

            // 4) Normalización suave (AGC ligero) solo cuando el gate está abierto.
            let coeff: Float = mag > envelope ? 0.4 : 0.02
            envelope += (mag - envelope) * coeff
            if envelope > 0.0001 {
                s *= min(3.0, 0.4 / envelope)
            }

            s = max(-1.0, min(1.0, s))
            samples[i] = Int16(s * 32767.0)
        }
    }

    // MARK: - Diseño de biquads (fórmulas RBJ Audio EQ Cookbook)

    private func makeHighpass(freq: Double, sampleRate: Double) -> BiquadState {
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let q = 0.707
        let alpha = sinw / (2 * q)

        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return normalized(b0, b1, b2, a0, a1, a2)
    }

    private func makeLowpass(freq: Double, sampleRate: Double) -> BiquadState {
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let q = 0.707
        let alpha = sinw / (2 * q)

        let b0 = (1 - cosw) / 2
        let b1 = 1 - cosw
        let b2 = (1 - cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return normalized(b0, b1, b2, a0, a1, a2)
    }

    private func makePeaking(freq: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadState {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)

        let b0 = 1 + alpha * A
        let b1 = -2 * cosw
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cosw
        let a2 = 1 - alpha / A
        return normalized(b0, b1, b2, a0, a1, a2)
    }

    private func normalized(_ b0: Double, _ b1: Double, _ b2: Double,
                            _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadState {
        var s = BiquadState()
        s.b0 = Float(b0 / a0); s.b1 = Float(b1 / a0); s.b2 = Float(b2 / a0)
        s.a1 = Float(a1 / a0); s.a2 = Float(a2 / a0)
        return s
    }
}
