import Foundation
import ProtoDefinitions
import SwiftProtobuf

// Конвертация между моделями приложения и proto. Модели GRDB о proto не знают — всё здесь.

extension UUID {
    var protoData: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init(protoData data: Data) throws {
        guard data.count == 16 else { throw APIError(message: "Некорректный идентификатор от сервера") }
        let bytes = [UInt8](data)
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func optional(_ data: Data, has: Bool) throws -> UUID? {
        has && !data.isEmpty ? try UUID(protoData: data) : nil
    }
}

extension Date {
    var proto: Google_Protobuf_Timestamp { Google_Protobuf_Timestamp(date: self) }
}

extension SortMode {
    init(proto: SortMode_SortMode) {
        switch proto {
        case .priority: self = .priority
        case .plannedDay: self = .plannedDay
        case .deadline: self = .deadline
        case .duration: self = .duration
        default: self = .manual
        }
    }

    var proto: SortMode_SortMode {
        switch self {
        case .manual: .manual
        case .priority: .priority
        case .plannedDay: .plannedDay
        case .deadline: .deadline
        case .duration: .duration
        }
    }
}

// MARK: - Из proto

extension TaskList {
    init(proto p: TaskList_TaskList) throws {
        self.init(id: try UUID(protoData: p.id), name: p.name, isInbox: p.isInbox, colorHex: p.colorHex,
                  icon: p.icon.isEmpty ? (p.isInbox ? "tray.fill" : TaskList.icons[0]) : p.icon,
                  sortOrder: p.sortOrder, sortMode: SortMode(proto: p.sortMode),
                  createdAt: p.createdAt.date, updatedAt: p.updatedAt.date)
    }
}

extension ListSection {
    init(proto p: ListSection_ListSection) throws {
        self.init(id: try UUID(protoData: p.id), listId: try UUID(protoData: p.listID), name: p.name,
                  sortOrder: p.sortOrder, updatedAt: p.updatedAt.date)
    }
}

extension Priority {
    init(proto p: Priority_Priority) throws {
        self.init(id: try UUID(protoData: p.id), name: p.name, colorHex: p.colorHex, marks: p.marks,
                  sortOrder: p.sortOrder, updatedAt: p.updatedAt.date)
    }
}

extension DurationOption {
    init(proto p: DurationOption_DurationOption) throws {
        self.init(id: try UUID(protoData: p.id), title: p.title, minutes: Int(p.minutes), updatedAt: p.updatedAt.date)
    }
}

extension TaskItem {
    init(proto p: Task_Task) throws {
        self.init(
            id: try UUID(protoData: p.id),
            listId: try UUID(protoData: p.listID),
            sectionId: try UUID.optional(p.sectionID, has: p.hasSectionID),
            title: p.title,
            notes: p.notes,
            priorityId: try UUID.optional(p.priorityID, has: p.hasPriorityID),
            plannedDay: p.hasPlannedDay && !p.plannedDay.isEmpty ? p.plannedDay : nil,
            deadlineDay: p.hasDeadlineDay && !p.deadlineDay.isEmpty ? p.deadlineDay : nil,
            durationMinutes: p.hasDurationMinutes && p.durationMinutes != 0 ? Int(p.durationMinutes) : nil,
            manualOrder: p.manualOrder,
            completedAt: p.hasCompletedAt ? p.completedAt.date : nil,
            externalId: p.hasExternalID ? p.externalID : nil,
            createdAt: p.createdAt.date,
            updatedAt: p.updatedAt.date
        )
    }
}

extension Tag {
    init(proto p: Tag_Tag) throws {
        self.init(id: try UUID(protoData: p.id), name: p.name, updatedAt: p.updatedAt.date)
    }
}

extension TaskTag {
    init(proto p: Tag_TaskToTag) throws {
        self.init(taskId: try UUID(protoData: p.taskID), tagId: try UUID(protoData: p.tagID), updatedAt: p.updatedAt.date)
    }
}

extension Blocker {
    init(proto p: Blocker_Blocker) throws {
        self.init(
            id: try UUID(protoData: p.id),
            taskId: try UUID(protoData: p.taskID),
            blockingTaskId: try UUID.optional(p.blockingTaskID, has: p.hasBlockingTaskID),
            reason: p.hasBlockingTaskID && !p.blockingTaskID.isEmpty ? nil : (p.hasReason ? p.reason : ""),
            sinceDay: p.sinceDay,
            resolvedAt: p.hasResolvedAt ? p.resolvedAt.date : nil,
            updatedAt: p.updatedAt.date
        )
    }
}

extension SyncChanges {
    init(proto r: Sync_SyncResponse) throws {
        let ids = { (list: [Data]) in try list.map { try UUID(protoData: $0) } }
        self.init(
            checkpoint: r.pendingCheckpoint,
            syncToken: r.hasChanges_p ? r.pendingSyncToken : nil,
            lists: try r.changedTaskLists.map(TaskList.init(proto:)),
            deletedLists: try ids(r.deletedTaskListIds),
            sections: try r.changedListSections.map(ListSection.init(proto:)),
            deletedSections: try ids(r.deletedListSectionIds),
            priorities: try r.changedPriorities.map(Priority.init(proto:)),
            deletedPriorities: try ids(r.deletedPriorityIds),
            durations: try r.changedDurationOptions.map(DurationOption.init(proto:)),
            deletedDurations: try ids(r.deletedDurationOptionIds),
            tasks: try r.changedTasks.map(TaskItem.init(proto:)),
            deletedTasks: try ids(r.deletedTaskIds),
            tags: try r.changedTags.map(Tag.init(proto:)),
            deletedTags: try ids(r.deletedTagIds),
            addedTaskTags: try r.addedTasksToTags.map(TaskTag.init(proto:)),
            removedTaskTags: try r.removedTasksToTags.map(TaskTag.init(proto:)),
            blockers: try r.changedBlockers.map(Blocker.init(proto:)),
            deletedBlockers: try ids(r.deletedBlockerIds),
            dailyCapacityMinutes: r.hasChangedSettings && r.changedSettings.dailyCapacityMinutes > 0
                ? Int(r.changedSettings.dailyCapacityMinutes) : nil
        )
    }
}
