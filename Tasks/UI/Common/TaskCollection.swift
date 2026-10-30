import SwiftUI
import UIKit

/// Элемент ленты: задача или произвольная строка (сводка, заголовок раздела, новая задача).
/// Строка ввода новой задачи — с id на `new`: её ячейка не перерисовывается, чтобы не терять фокус.
enum TaskCollectionItem {
    case task(TaskRow, showList: String? = nil, hidesTodayDate: Bool = false)
    case view(id: String, AnyView)

    var id: String {
        switch self {
        case .task(let row, _, _): "task:" + row.id.uuidString
        case .view(let id, _): id
        }
    }

    var taskId: UUID? {
        if case .task(let row, _, _) = self { return row.id }
        return nil
    }

    /// Задача по id элемента ленты (`task:UUID`).
    static func taskId(of itemId: String) -> UUID? {
        itemId.hasPrefix("task:") ? UUID(uuidString: String(itemId.dropFirst(5))) : nil
    }
}

/// Лента задач на `UICollectionView`, как в Напоминаниях: системные свайп, выбор двумя пальцами
/// (на Mac — Cmd/Shift-клик) и перетаскивание. Ячейки — SwiftUI (`TaskRowView`, раскрытая задача).
/// Тап по задаче раскрывает быстрые действия, в режиме выбора — отмечает её.
struct TaskCollection: View {
    let items: [TaskCollectionItem]
    let board: Board
    /// Тап по пустому месту под задачами.
    var onEmptyTap: (() -> Void)?
    /// Бросок задач между элементами `previous` и `next` (id элементов ленты). `nil` — переставлять нельзя.
    var onDrop: ((_ payload: [String], _ previous: String?, _ next: String?) -> Bool)?
    @State private var opened: UUID?
    @Environment(\.taskSelection) private var selection

    var body: some View {
        // Состояние выбора читается здесь, чтобы его изменения перерисовывали ленту
        Representable(items: items, board: board, onEmptyTap: onEmptyTap, onDrop: onDrop, onOpen: { opened = $0 },
                      selectionState: SelectionSnapshot(isSelecting: selection?.isSelecting ?? false,
                                                        selected: selection?.selected ?? [], expanded: selection?.expanded))
            .ignoresSafeArea(.container, edges: .bottom)
            // Ячейки живут в UIKit — `NavigationLink` из них стек не видит, карточку открываем отсюда
            .navigationDestination(item: $opened) { TaskDetailScreen(taskId: $0) }
    }
}

extension EnvironmentValues {
    /// Открыть карточку задачи из ячейки `TaskCollection`.
    @Entry var openTask: ((UUID) -> Void)? = nil
}

private struct SelectionSnapshot: Equatable {
    var isSelecting: Bool
    var selected: Set<UUID>
    var expanded: UUID?
}

private struct Representable: UIViewControllerRepresentable {
    let items: [TaskCollectionItem]
    let board: Board
    let onEmptyTap: (() -> Void)?
    let onDrop: (([String], String?, String?) -> Bool)?
    let onOpen: (UUID) -> Void
    let selectionState: SelectionSnapshot

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICollectionViewController {
        let coordinator = context.coordinator
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        config.trailingSwipeActionsConfigurationProvider = { [weak coordinator] indexPath in
            coordinator?.swipeActions(at: indexPath)
        }
        let controller = UICollectionViewController(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        let collection = controller.collectionView!
        collection.backgroundColor = .clear
        collection.allowsMultipleSelectionDuringEditing = true
        collection.contentInset.bottom = 80
        collection.keyboardDismissMode = .interactive
        collection.dragInteractionEnabled = true // на iPhone по умолчанию выключено
        collection.delegate = coordinator
        collection.dragDelegate = coordinator
        collection.dropDelegate = coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.backgroundTap(_:)))
        tap.cancelsTouchesInView = false
        collection.addGestureRecognizer(tap)
        coordinator.attach(collection)
        return controller
    }

    func updateUIViewController(_ controller: UICollectionViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.selection = context.environment.taskSelection
        coordinator.database = context.environment.database
        coordinator.update(animated: !context.transaction.disablesAnimations)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        var parent: Representable?
        var selection: TaskSelectionState?
        var database: AppDatabase?
        private weak var collection: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var itemsById: [String: TaskCollectionItem] = [:]
        private var order: [String] = []

        func attach(_ collection: UICollectionView) {
            self.collection = collection
            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, indexPath, id in
                collection.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
        }

        /// Новый снимок: добавленные и убранные элементы — с анимацией, остальные перерисовываются на месте.
        func update(animated: Bool) {
            guard let parent, let dataSource, let collection else { return }
            itemsById = Dictionary(parent.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            order = parent.items.map(\.id).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(order)
            let old = Set(dataSource.snapshot().itemIdentifiers)
            // Строку ввода не перерисовываем: новая конфигурация ячейки сбрасывает фокус в её поле
            snapshot.reconfigureItems(order.filter { old.contains($0) && !$0.hasPrefix("new") })
            dataSource.apply(snapshot, animatingDifferences: animated && !old.isEmpty)
            syncSelection(collection)
        }

        /// Режим выбора и отметки — из общего состояния экрана (панель действий снимает их после действия).
        private func syncSelection(_ collection: UICollectionView) {
            let selecting = selection?.isSelecting ?? false
            if collection.isEditing != selecting { collection.isEditing = selecting }
            let wanted = selecting ? (selection?.selected ?? []) : []
            for indexPath in collection.indexPathsForSelectedItems ?? [] {
                if let id = taskId(at: indexPath), !wanted.contains(id) { collection.deselectItem(at: indexPath, animated: false) }
            }
            for id in wanted {
                if let indexPath = dataSource?.indexPath(for: "task:" + id.uuidString),
                   !(collection.indexPathsForSelectedItems ?? []).contains(indexPath) {
                    collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
                }
            }
        }

        private func configure(_ cell: UICollectionViewListCell, id: String) {
            guard let parent, let item = itemsById[id] else { return }
            cell.backgroundConfiguration = .clear()
            let padding: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 9 : 6
            let content: AnyView
            switch item {
            case .task(let row, let showList, let hidesTodayDate):
                if selection?.expanded == row.id, selection?.isSelecting != true {
                    content = AnyView(ExpandedTaskRow(row: row, board: parent.board) { [weak self] in
                        self?.selection?.expanded = nil
                    })
                } else {
                    content = AnyView(TaskRowView(row: row, showList: showList, hidesTodayDate: hidesTodayDate, board: parent.board)
                        .frame(maxWidth: .infinity, alignment: .leading))
                }
            case .view(_, let view):
                content = view
            }
            cell.contentConfiguration = UIHostingConfiguration {
                content
                    .environment(\.database, database ?? EnvironmentValues().database)
                    .environment(\.taskSelection, selection)
                    .environment(\.taskBoard, parent.board)
                    .environment(\.openTask, parent.onOpen)
            }
            .margins(.horizontal, 16)
            .margins(.vertical, item.taskId == nil ? 0 : padding)
        }

        private func taskId(at indexPath: IndexPath) -> UUID? {
            dataSource?.itemIdentifier(for: indexPath).flatMap { itemsById[$0]?.taskId }
        }

        // MARK: Тап и выбор

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            taskId(at: indexPath) != nil
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = taskId(at: indexPath), let selection else { return }
            if collectionView.isEditing {
                selection.selected.insert(id)
            } else {
                collectionView.deselectItem(at: indexPath, animated: false)
                selection.expanded = id
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard collectionView.isEditing, let id = taskId(at: indexPath) else { return }
            selection?.selected.remove(id)
        }

        /// Протяжка двумя пальцами (на Mac — Cmd/Shift-клик) сразу включает режим выбора.
        func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            taskId(at: indexPath) != nil
        }

        func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            guard let selection, !selection.isSelecting else { return }
            selection.expanded = nil
            selection.selected = []
            selection.isSelecting = true
            collectionView.isEditing = true
        }

        /// Тап мимо задач: закрывает раскрытую задачу, под задачами — `onEmptyTap`.
        @objc func backgroundTap(_ recognizer: UITapGestureRecognizer) {
            guard let collection, let selection else { return }
            let point = recognizer.location(in: collection)
            guard collection.indexPathForItem(at: point) == nil else { return }
            if selection.expanded != nil {
                selection.expanded = nil
                return
            }
            let bottom = collection.visibleCells.map(\.frame.maxY).max() ?? 0
            if point.y > bottom, !selection.isSelecting { parent?.onEmptyTap?() }
        }

        // MARK: Свайп

        func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let id = taskId(at: indexPath), collection?.isEditing != true else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Удалить") { [weak self] _, _, done in
                try? self?.database?.deleteTask(id)
                done(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }

        // MARK: Перетаскивание

        /// Тянется отмеченная задача — значит, все отмеченные, как в Напоминаниях.
        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem] {
            guard let id = taskId(at: indexPath) else { return [] }
            var ids = [id]
            if let selection, selection.isSelecting, selection.selected.contains(id) { ids = Array(selection.selected) }
            let provider = NSItemProvider(object: DragPayload.tasks(ids) as NSString)
            return [UIDragItem(itemProvider: provider)]
        }

        func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
            parent?.onDrop != nil && session.canLoadObjects(ofClass: NSString.self)
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard parent?.onDrop != nil else { return UICollectionViewDropProposal(operation: .forbidden) }
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard let onDrop = parent?.onDrop else { return }
            let index = coordinator.destinationIndexPath?.item ?? order.count
            let previous = index > 0 && index - 1 < order.count ? order[index - 1] : nil
            let next = index < order.count ? order[index] : nil
            _ = coordinator.session.loadObjects(ofClass: NSString.self) { strings in
                _ = onDrop(strings.compactMap { $0 as? String }, previous, next)
            }
        }
    }
}
