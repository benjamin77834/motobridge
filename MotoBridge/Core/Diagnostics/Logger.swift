import Foundation
import Combine

/// Niveles de severidad de log (sección 15).
enum LogLevel: String, Codable, CaseIterable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    private var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.order < rhs.order
    }
}

/// Categorías de evento que exige registrar la sección 15.
enum LogCategory: String, Codable, CaseIterable {
    case bluetooth = "Bluetooth"
    case audioSession = "AudioSession"
    case audioRoute = "AudioRoute"
    case connection = "Connection"
    case interruption = "Interruption"
    case bridge = "Bridge"
    case latency = "Latency"
    case general = "General"
    case error = "Error"
}

/// Una entrada de log inmutable.
struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String

    init(level: LogLevel, category: LogCategory, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
    }

    /// Línea formateada para el archivo de diagnóstico.
    var formattedLine: String {
        let ts = LogEntry.dateFormatter.string(from: timestamp)
        return "[\(ts)] [\(level.rawValue)] [\(category.rawValue)] \(message)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Logger central de la app. Mantiene un buffer en memoria acotado y publica
/// las entradas para la UI. Permite exportar un archivo de diagnóstico (sección 15).
///
/// No registra información personal innecesaria: solo eventos técnicos.
final class Logger: ObservableObject {
    static let shared = Logger()

    /// Entradas publicadas (las más recientes al final).
    @Published private(set) var entries: [LogEntry] = []

    /// Nivel mínimo que se retiene. En release podría subirse a .info.
    var minimumLevel: LogLevel = .debug

    /// Límite del buffer en memoria para no crecer sin control.
    private let maxEntries = 2000

    private let queue = DispatchQueue(label: "com.motobridge.logger", qos: .utility)

    private init() {}

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        guard level >= minimumLevel else { return }
        let entry = LogEntry(level: level, category: category, message: message)

        // Consola para desarrollo.
        print(entry.formattedLine)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    // Atajos.
    func debug(_ category: LogCategory, _ message: String) { log(.debug, category, message) }
    func info(_ category: LogCategory, _ message: String) { log(.info, category, message) }
    func warning(_ category: LogCategory, _ message: String) { log(.warning, category, message) }
    func error(_ category: LogCategory, _ message: String) { log(.error, category, message) }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    /// Genera el texto completo del diagnóstico.
    func exportText() -> String {
        let header = """
        MotoBridge — Diagnostic Export
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        Entries: \(entries.count)
        ------------------------------------------------------------
        """
        let body = entries.map { $0.formattedLine }.joined(separator: "\n")
        return header + "\n" + body + "\n"
    }

    /// Escribe el diagnóstico a un archivo temporal y devuelve su URL
    /// (para usar con un share sheet). Devuelve nil si falla la escritura.
    func exportToFile() -> URL? {
        let filename = "MotoBridge-Diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            self.error(.error, "No se pudo exportar el diagnóstico: \(error.localizedDescription)")
            return nil
        }
    }
}
