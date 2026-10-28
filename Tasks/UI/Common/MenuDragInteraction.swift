import SwiftUI
import UIKit

/// Меню по долгому нажатию (на Mac — правый клик) и перетаскивание на одном элементе, как в Напоминаниях:
/// подержал — меню, повёл пальцем — меню закрывается и начинается перетаскивание.
/// В SwiftUI `.contextMenu` и `.onDrag` на одном виде так не умеют — долгое нажатие достаётся кому-то одному,
/// поэтому оба жеста ставятся UIKit-взаимодействиями на прозрачный слой поверх строки.
struct MenuDragInteraction: UIViewRepresentable {
    /// Что перетаскивается.
    let payload: () -> String
    /// Заголовок и цвет значка перетаскивания и превью меню.
    let title: String
    let colorHex: String
    let actions: [UIAction]
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true // на iPhone по умолчанию выключено
        view.addInteraction(drag)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
        var parent: MenuDragInteraction?

        @objc func tap() { parent?.onTap() }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let actions = parent?.actions, !actions.isEmpty else { return nil }
            return UIContextMenuConfiguration(actionProvider: { _ in UIMenu(children: actions) })
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            return UITargetedPreview(view: badge(), parameters: clearParameters(),
                                     target: UIPreviewTarget(container: view, center: CGPoint(x: view.bounds.minX + 90, y: view.bounds.midY)))
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            guard let payload = parent?.payload() else { return [] }
            return [UIDragItem(itemProvider: NSItemProvider(object: payload as NSString))]
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                             session: any UIDragSession) -> UITargetedDragPreview? {
            guard let view = interaction.view else { return nil }
            return UITargetedDragPreview(view: badge(), parameters: UIDragPreviewParameters(),
                                         target: UIDragPreviewTarget(container: view, center: session.location(in: view)))
        }

        /// Компактная плашка: цветной кружок и название — вместо снимка прозрачного слоя.
        private func badge() -> UIView {
            let label = UILabel()
            label.text = parent?.title
            label.font = .preferredFont(forTextStyle: .body)
            let dot = UIView()
            dot.backgroundColor = UIColor(Color(hex: parent?.colorHex ?? "#3E9BF0"))
            dot.layer.cornerRadius = 7
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14)])
            let stack = UIStackView(arrangedSubviews: [dot, label])
            stack.spacing = 8
            stack.alignment = .center
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            stack.backgroundColor = .secondarySystemGroupedBackground
            stack.layer.cornerRadius = 10
            stack.frame.size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            return stack
        }

        private func clearParameters() -> UIPreviewParameters {
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            return parameters
        }
    }
}
