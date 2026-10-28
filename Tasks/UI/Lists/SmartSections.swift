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
            ForEach(DurationBucket.allCases, id: \.self) { bucket in
                chip(.duration(bucket), drop: .duration(bucket.minutes)) {
                    Text("⏱ " + bucket.title)
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
        Section(title) {
            FlowLayout(spacing: 8) { content() }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
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
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids { try? database.assign(drop, to: id) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private var background: Color {
        if targeted || isSelected { return Color.accentColor.opacity(0.35) }
        return Color(.tertiarySystemFill)
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

/// Цель для перетаскивания задачи: брошенная задача получает значение объекта.
private struct TaskDropTarget: ViewModifier {
    let assignment: AppDatabase.Assignment
    @Environment(\.database) private var database
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(UUID.init(uuidString:))
                for id in ids { try? database.assign(assignment, to: id) }
                return !ids.isEmpty
            } isTargeted: { targeted = $0 }
            .listRowBackground(targeted ? Color.accentColor.opacity(0.2) : nil)
    }
}

extension View {
    func taskDrop(_ assignment: AppDatabase.Assignment) -> some View {
        modifier(TaskDropTarget(assignment: assignment))
    }
}

/// Задачи подборки: приоритета, корзины длительности или тега.
struct FilteredScreen: View {
    let filter: TaskFilter
    @Environment(\.database) private var database
    @State private var board = Board()

    var body: some View {
        let rows = board.rows(matching: filter)
        List {
            ForEach(rows) { row in
                NavigationLink(value: row.id) {
                    TaskRowView(row: row, showList: board.list(row.task.listId)?.name, board: board)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { if rows.isEmpty { ContentUnavailableView("Нет задач", systemImage: "tray") } }
        .navigationTitle(board.title(of: filter))
        .navigationDestination(for: UUID.self) { TaskDetailScreen(taskId: $0) }
        .observingBoard($board, in: database)
    }
}
