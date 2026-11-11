import Foundation
import SwiftUI

extension AppModel {
    func inboxID(forSessionPath path: String) -> String {
        "session:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }

    func inboxID(for controller: SessionController) -> String {
        if let sessionPath = controller.sessionPath { return inboxID(forSessionPath: sessionPath) }
        return "controller:\(controller.id)"
    }

    func inboxController(for itemID: String) -> SessionController? {
        if itemID.hasPrefix("controller:") {
            return controllers[String(itemID.dropFirst("controller:".count))]
        }
        guard let path = sessionPath(fromInboxID: itemID) else { return nil }
        return controller(forSessionPath: path)
    }

    func inboxSummary(for itemID: String) -> SessionSummary? {
        guard let path = sessionPath(fromInboxID: itemID) else { return nil }
        return sessionSummary(forPath: path)
    }

    func inboxParentID(for itemID: String) -> String? {
        guard let parentPath = inboxSummary(for: itemID)?.parentSessionPath else { return nil }
        return inboxID(forSessionPath: parentPath)
    }

    func isQuickChatInboxItem(_ itemID: String) -> Bool {
        if let controller = inboxController(for: itemID) { return controller.isQuickChat }
        guard let summary = inboxSummary(for: itemID) else { return false }
        return agentSessionRecords[AgentSessionStore.standardizedPath(summary.filePath)] == nil && isQuickChatsProject(summary.projectPath)
    }

    var canUndoInboxDismissal: Bool { inboxDismissalUndo != nil }

    var inboxDismissalUndoTitle: String? { inboxDismissalUndo?.title }

    func markInboxItemDone(_ itemID: String) {
        let removedIDs: Set<String>
        if inboxParentID(for: itemID) == nil {
            removedIDs = Set([itemID] + sessionInboxIDs.filter { inboxParentID(for: $0) == itemID })
        } else {
            removedIDs = [itemID]
        }
        guard !removedIDs.contains(where: {
            inboxController(for: $0)?.hasLiveWork == true || inboxHermesController(for: $0)?.isWorking == true
        }) else {
            statusLine = "A working chat cannot be marked done."
            return
        }

        let removedItems = sessionInboxIDs.enumerated().compactMap { index, id in
            removedIDs.contains(id) ? (id: id, index: index) : nil
        }
        guard !removedItems.isEmpty else { return }
        let removedControllers = controllers.values.filter { controller in
            removedIDs.contains(inboxID(for: controller)) || removedIDs.contains("controller:\(controller.id)")
        }
        let removedSelectedControllerID = selectedController.flatMap { controller -> String? in
            let selectedIDs = Set([inboxID(for: controller), "controller:\(controller.id)"])
            return removedIDs.isDisjoint(with: selectedIDs) ? nil : controller.id
        }
        let removedSelectedHermesChatID = selectedHermesChatID.flatMap { removedIDs.contains("hermes:\($0)") ? $0 : nil }
        let title = inboxHermesChat(for: itemID)?.title ?? inboxController(for: itemID)?.title ?? inboxSummary(for: itemID)?.title ?? "Chat"
        inboxDismissalUndo = InboxDismissalUndo(
            items: removedItems,
            selectedControllerID: removedSelectedControllerID,
            selectedHermesChatID: removedSelectedHermesChatID,
            title: title.isEmpty ? "Untitled" : title
        )
        sessionInboxIDs.removeAll { removedIDs.contains($0) }
        for controller in removedControllers {
            controller.suspendRuntime()
            finishedUnseenControllerIDs.remove(controller.id)
            activeControllerIDs.remove(controller.id)
        }

        for record in hermesChats where removedIDs.contains("hermes:\(record.id)") {
            hermesControllers[record.id]?.stop()
            hermesUnreadChatIDs.remove(record.id)
        }

        if removedSelectedControllerID != nil || removedSelectedHermesChatID != nil {
            clearAgentSelection()
            selectedControllerID = nil
            composingQuickChat = false
            newChatHomeRequestID += 1
        }
    }

    func undoLastInboxDismissal() {
        guard let undo = inboxDismissalUndo else { return }
        for item in undo.items.sorted(by: { $0.index < $1.index }) where !sessionInboxIDs.contains(item.id) {
            sessionInboxIDs.insert(item.id, at: min(item.index, sessionInboxIDs.endIndex))
        }
        if let controllerID = undo.selectedControllerID, let controller = controllers[controllerID] {
            clearAgentSelection()
            selectedControllerID = controllerID
            selectedProjectPath = controller.projectPath
            composingQuickChat = false
        }
        if let chatID = undo.selectedHermesChatID, let chat = hermesChats.first(where: { $0.id == chatID }) {
            selectHermesChat(agentID: chat.agentID, chatID: chatID)
        }
        inboxDismissalUndo = nil
        statusLine = "Restored: \(undo.title)"
    }

    func moveInboxItem(_ draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              sessionInboxIDs.contains(draggedID),
              sessionInboxIDs.contains(targetID) else { return }

        let draggedParent = inboxParentID(for: draggedID)
        let targetParent = inboxParentID(for: targetID)
        if draggedParent != nil || targetParent != nil {
            guard draggedParent == targetParent, draggedParent != nil else { return }
            sessionInboxIDs.removeAll { $0 == draggedID }
            guard let targetIndex = sessionInboxIDs.firstIndex(of: targetID) else { return }
            sessionInboxIDs.insert(draggedID, at: targetIndex + (after ? 1 : 0))
            return
        }

        let moving = sessionInboxIDs.filter { $0 == draggedID || inboxParentID(for: $0) == draggedID }
        sessionInboxIDs.removeAll { moving.contains($0) }
        guard let targetIndex = sessionInboxIDs.firstIndex(of: targetID) else {
            sessionInboxIDs.append(contentsOf: moving)
            return
        }
        let targetChildren = sessionInboxIDs.filter { inboxParentID(for: $0) == targetID }
        let insertionIndex = after ? targetIndex + 1 + targetChildren.count : targetIndex
        sessionInboxIDs.insert(contentsOf: moving, at: min(insertionIndex, sessionInboxIDs.endIndex))
    }

    private func sessionPath(fromInboxID itemID: String) -> String? {
        guard itemID.hasPrefix("session:") else { return nil }
        return String(itemID.dropFirst("session:".count))
    }

    private func sessionSummary(forPath path: String) -> SessionSummary? {
        for sessions in sessionsByProject.values {
            if let summary = sessions.first(where: { $0.filePath == path }) { return summary }
        }
        for sessions in archivedSessionsByProject.values {
            if let summary = sessions.first(where: { $0.filePath == path }) { return summary }
        }
        return nil
    }

    func removeHermesInboxItem(_ chatID: String) {
        let itemID = "hermes:\(chatID)"
        sessionInboxIDs.removeAll { $0 == itemID }
        if inboxDismissalUndo?.items.contains(where: { $0.id == itemID }) == true {
            inboxDismissalUndo = nil
        }
    }

    func appendInboxID(_ itemID: String) {
        guard !sessionInboxIDs.contains(itemID) else { return }
        sessionInboxIDs.append(itemID)
    }

    func addControllerToInbox(_ controller: SessionController) {
        let currentID = inboxID(for: controller)
        let transientID = "controller:\(controller.id)"
        if currentID != transientID, let transientIndex = sessionInboxIDs.firstIndex(of: transientID) {
            if !sessionInboxIDs.contains(currentID) {
                sessionInboxIDs[transientIndex] = currentID
            } else {
                sessionInboxIDs.remove(at: transientIndex)
            }
            return
        }
        appendInboxID(currentID)
    }

    func addSessionToInbox(_ summary: SessionSummary) {
        if summary.isChildSession,
           let parentPath = summary.parentSessionPath,
           let parent = sessionSummary(forPath: parentPath) {
            appendInboxID(inboxID(forSessionPath: parent.filePath))
        }
        appendInboxID(inboxID(forSessionPath: summary.filePath))
    }

    func syncControllerInboxID(_ controller: SessionController) {
        guard controller.sessionPath != nil else { return }
        let transientID = "controller:\(controller.id)"
        let stableID = inboxID(for: controller)
        guard sessionInboxIDs.contains(transientID) || sessionInboxIDs.contains(stableID) else { return }
        addControllerToInbox(controller)
    }

    func loadPersistedInboxSummaries() async {
        let paths = sessionInboxIDs.compactMap(sessionPath(fromInboxID:))
        guard !paths.isEmpty else { return }
        let grouped = await SessionScanner.cachedSummaries(forPaths: paths)
        guard !grouped.isEmpty else { return }
        sessionsByProject = grouped
        projects = sortedProjects(projects, grouped: grouped)
    }

}
