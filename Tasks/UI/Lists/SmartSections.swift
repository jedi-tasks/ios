import SwiftUI

/// Разделы под списками: приоритеты, длительность, теги — облаком плашек, как теги в Напоминаниях.
/// Тап по плашке открывает подборку; брошенная на плашку задача получает её значение.
struct SmartSections: View {
    let board: Board
    var selected: TaskFilter?
    let onSelect: (TaskFilter) -> Void

    var body: some View {
        chips("Приоритеты") {
            ForEach(board.priorities) { priority in
                chip(.priority(priority.id), drop: .priority(priority.id)) {
                    Text(priority.marks).bold().foregroundStyle(Color(hex: priority.colorHex)) + Text(" " + priority.name)
                }
            }
            chip(.priority(nil), drop: .priority(nil)) { Text("Не разобрано") }
        }
        chips("Длительность") {
            ForEach(board.durations) { option in
                chip(.duration(option.minutes), drop: .duration(option.minutes)) {
                    Text("⏱ " + option.title)
                }
            }
        }
        if !board.tags.isEmpty {
            chips("Теги") {
                ForEach(board.tags) { tag in
                    chip(.tag(tag.id), drop: .tag(tag.id)) { Text("#" + tag.name) }
                }
            }
        }
    }

    private func chips(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) { content() }
        }
        .padding(.top, 16)
    }

    private func chip(_ filter: TaskFilter, drop: AppDatabase.Assignment, label: () -> Text) -> some View {
        Chip(label: label(), count: board.rows(matching: filter).count, isSelected: selected == filter, drop: drop) {
            onSelect(filter)
        }
    }
}

/// Плашка подборки: скруглённый прямоугольник, подсвечивается при выборе и при наведении задачи.
private struct Chip: View {
    let label: Text
    let count: Int
    let isSelected: Bool
    let drop: AppDatabase.Assignment
    let action: () -> Void
    @Environment(\.database) private var database
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label
                if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
            }
            .font(.body)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            let ids = items.flatMap(DragPayload.taskIds)
            for id in ids { try? database.assign(drop, to: id) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private var background: Color {
        if targeted || isSelected { return Color.accentColor.opacity(0.35) }
        return Color(.secondarySystemGroupedBackground)
    }
}

/// Раскладка «по строкам с переносом» для плашек.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Задачи подборки: приоритета, корзины длительности или тега.
struct FilteredScreen: View {
    let filter: TaskFilter
    @Environment(\.database) private var database
    @State private var board = Board()

    var body: some View {
        let rows = board.rows(matching: filter)
        TaskScroll {
            ForEach(rows) { row in
                TaskLink(id: row.id) {
                    TaskRowView(row: row, showList: board.list(row.task.listId)?.name, board: board)
                }
            }
        }
        .overlay { if rows.isEmpty { ContentUnavailableView("Нет задач", systemImage: "tray") } }
        .navigationTitle(board.title(of: filter))
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .taskSelection(board: board)
        .observingBoard($board, in: database)
    }
}
