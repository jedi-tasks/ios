import GRDB
import SwiftUI

extension EnvironmentValues {
    @Entry var database: AppDatabase = try! .makeInMemory()
}

extension View {
    /// Держит `value` актуальным, наблюдая за базой.
    func observing<T: Sendable>(
        _ value: Binding<T>,
        in database: AppDatabase,
        fetch: @escaping @Sendable (Database) throws -> T
    ) -> some View {
        task {
            do {
                for try await next in database.observe(fetch) {
                    value.wrappedValue = next
                }
            } catch {}
        }
    }

    /// Наблюдает за всем снимком данных.
    func observingBoard(_ board: Binding<Board>, in database: AppDatabase) -> some View {
        observing(board, in: database, fetch: AppDatabase.fetchBoard)
    }
}

/// Запуск действия с базой с показом ошибки в алерте.
@MainActor
@Observable
final class ErrorAlert {
    var message: String?

    func run(_ action: () throws -> Void) {
        do { try action() } catch { message = error.localizedDescription }
    }
}

extension View {
    func errorAlert(_ alert: ErrorAlert) -> some View {
        self.alert("Ошибка", isPresented: Binding(
            get: { alert.message != nil },
            set: { if !$0 { alert.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert.message ?? "")
        }
    }
}

extension Color {
    init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        let c = UIColor(self).cgColor.components ?? [0.5, 0.5, 0.5]
        let rgb = c.count >= 3 ? c : [c[0], c[0], c[0]]
        return String(format: "#%02X%02X%02X", Int(rgb[0] * 255), Int(rgb[1] * 255), Int(rgb[2] * 255))
    }
}
