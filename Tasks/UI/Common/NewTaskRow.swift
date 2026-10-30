import SwiftUI

/// Куда добавляется новая задача строкой прямо в списке.
struct NewTaskTarget: Equatable {
    var sectionId: UUID?
}

/// Пустая строка новой задачи, как в Напоминаниях: курсор сразу в ней.
/// Enter сохраняет и открывает следующую строку; уход с пустой строки — убирает её.
/// Строку убрали снаружи (тап по пустому месту) — набранное сохраняется.
struct NewTaskRow: View {
    var colorHex: String
    /// Сохраняет задачу с названием; вызывается только для непустого текста.
    let onCommit: (String) -> Void
    let onEnd: () -> Void
    @State private var title = ""
    @FocusState private var focused: Bool
    /// Enter с текстом: на iPhone клавиатура всё равно уходит, и строку надо вернуть, а не закрыть.
    @State private var continuing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckCircle()
            TextField("", text: $title)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit {
                    // Пустой Enter — закончить; иначе сохранить и остаться в строке для следующей задачи
                    if title.trimmingCharacters(in: .whitespaces).isEmpty {
                        focused = false
                    } else {
                        commit()
                        continuing = true
                        focused = true
                    }
                }
        }
        .listRowSeparator(.hidden)
        .onAppear { focused = true }
        .onDisappear(perform: commit)
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else {
                continuing = false
                return
            }
            if continuing {
                continuing = false
                focused = true
                return
            }
            commit()
            onEnd()
        }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = ""
        if !trimmed.isEmpty { onCommit(trimmed) }
    }
}
