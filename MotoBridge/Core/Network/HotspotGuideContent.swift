import Foundation

/// Texto de la guía "Maximizar compatibilidad (hotspot)". Un solo archivo por
/// plataforma (spec hotspot-rider-guide R5.3). Se compila también en Mac Relay.
///
/// Notas para el equipo (no se muestran al rider):
/// - Que "Maximizar compatibilidad" fuerce la banda de 2,4 GHz lo dice la comunidad
///   de Apple (discussions.apple.com/thread/256014511), no una página oficial de
///   soporte. La opción existe en iPhone 12 o posterior (Apple Platform Security).
/// - No prometer alcance, velocidad ni porcentajes (R2.4, R2.5, R5.1).
/// - Pasos de Samsung One UI SIN validar en un S25 ni en un iPhone real todavía
///   (tareas 2.1 y 2.2 del spec). Anotar aquí la fecha y versión al validarlos.
/// - Revisar al cambiar la versión de iOS o Android objetivo.
enum HotspotGuideContent {
    struct Section: Identifiable {
        let title: String
        let steps: [String]
        var id: String { title }
    }

    static let entryTitle = "Maximizar compatibilidad (hotspot)"

    static let intro = "Si usas el hotspot de un rider para conectar a todos, estos pasos ayudan a que la red sea más estable."

    static let sections: [Section] = [
        Section(title: "Hotspot de iPhone", steps: [
            "Abre Ajustes y entra a Punto de acceso personal.",
            "Activa el interruptor \"Maximizar compatibilidad\". Está disponible en iPhone 12 o posterior.",
            "Hazlo si algún dispositivo no ve la red o la conexión se corta.",
            "Esta opción usa la banda de 2,4 GHz, que suele llegar más lejos pero es más lenta y más sensible a interferencias."
        ]),
        Section(title: "Hotspot de Android (Samsung One UI)", steps: [
            "Abre Ajustes, Conexiones, Punto de acceso móvil y anclaje.",
            "Entra a Punto de acceso móvil y toca Configurar.",
            "En Banda, elige 2,4 GHz y guarda.",
            "En otros fabricantes los nombres pueden variar: busca la configuración del punto de acceso y elige la banda de 2,4 GHz."
        ]),
        Section(title: "Si se ven pero no hay audio", steps: [
            "Algunos hotspots impiden que los dispositivos se comuniquen entre sí (aislamiento de clientes). Prueba con el hotspot de otro rider o usa la conexión directa entre iPhones.",
            "Para incluir a Android y Mac, todos deben estar en la misma red Wi-Fi o hotspot."
        ]),
        Section(title: "Alcance", steps: [
            "El alcance depende de obstáculos, interferencias y de los dispositivos. No se promete ningún alcance concreto."
        ])
    ]

    /// Todo el texto visible, para la prueba de palabras prohibidas (R5.1).
    static var allText: String {
        ([entryTitle, intro] + sections.flatMap { [$0.title] + $0.steps }).joined(separator: "\n")
    }
}
