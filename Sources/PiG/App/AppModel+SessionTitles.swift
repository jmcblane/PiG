import Foundation
import SwiftUI
import AppKit

extension AppModel {
    func requestSessionRename(_ controller: SessionController) {
        guard let path = controller.sessionPath, !controller.showsActivityIndicator else { return }
        presentRenameDialog(SessionRenameRequest(filePath: path, title: controller.title))
    }

    func requestSessionRename(_ summary: SessionSummary) {
        guard activeController(forSessionPath: summary.filePath) == nil else { return }
        presentRenameDialog(SessionRenameRequest(filePath: summary.filePath, title: summary.title))
    }

    private func presentRenameDialog(_ request: SessionRenameRequest) {
        sessionPendingRename = request
        dialog = GlowDialogRequest(
            title: "Rename Chat",
            textInput: .init(placeholder: "Name", initialText: request.title),
            confirmTitle: "Rename",
            onConfirm: { [weak self] name in
                guard let self else { return }
                if let request = self.sessionPendingRename {
                    self.renameSession(request, to: name)
                }
                self.sessionPendingRename = nil
            },
            onCancel: { [weak self] in self?.sessionPendingRename = nil }
        )
    }

    func regenerateSessionTitle(path: String) {
        guard activeController(forSessionPath: path) == nil,
              !sessionsGeneratingTitles.contains(path) else { return }
        sessionsGeneratingTitles.insert(path)
        let controller = controller(forSessionPath: path)
        let mode = sessionNamingModelMode
        let modelID = mode == .specific ? sessionNamingModelID
            : (controller?.selectedModelID.nonEmptyTrimmed ?? DefaultModelSchedule.effectiveModelID() ?? "")
        let thinkingLevel = sessionNamingThinkingLevel
        statusLine = "Generating chat title…"
        Task {
            defer { sessionsGeneratingTitles.remove(path) }
            guard let parsed = await SessionParser.parseFileAsync(URL(fileURLWithPath: path)) else {
                statusLine = "Could not read chat for title generation."
                return
            }
            let conversation = SessionTitleGenerator.openingConversation(from: parsed.messages)
            guard !conversation.isEmpty else {
                statusLine = "No chat messages available to generate a title."
                return
            }
            var title: String?
            if mode != .apple {
                title = await SessionTitleGenerator.generate(from: conversation, modelID: modelID, thinkingLevel: thinkingLevel)
            }
            if title == nil {
                title = await AppleIntelligenceNaming.generateTitle(from: conversation)
            }
            guard let title else {
                statusLine = "Could not generate chat title. Check the naming model settings."
                return
            }
            guard let current = await SessionParser.parseFileAsync(URL(fileURLWithPath: path)),
                  current.summary.title == parsed.summary.title else {
                statusLine = "Chat changed while generating its title; title not replaced."
                return
            }
            renameSession(SessionRenameRequest(filePath: path, title: current.summary.title), to: title)
        }
    }

    func renameSession(_ request: SessionRenameRequest, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = request.filePath
        guard activeController(forSessionPath: path) == nil else {
            statusLine = "Cannot rename a working chat."
            return
        }
        let controller = controller(forSessionPath: path)
        if let controller, controller.hasRuntimeOrStartup {
            Task {
                if await controller.renameSession(name) {
                    refreshSessions()
                    if sessionArchiveLoadState == .loaded { loadSessionArchive() }
                }
            }
            return
        }
        Task {
            do {
                try await Task.detached {
                    try Self.appendSessionName(name, to: path)
                }.value
                controller?.title = name
                renameSummary(in: &sessionsByProject, path: path, to: name)
                renameSummary(in: &archivedSessionsByProject, path: path, to: name)
                refreshSessions()
                statusLine = "Chat renamed: \(name)"
            } catch {
                statusLine = "Could not rename chat: \(error.localizedDescription)"
            }
        }
    }

    private func renameSummary(in grouped: inout [String: [SessionSummary]], path: String, to name: String) {
        for project in grouped.keys {
            if let index = grouped[project]?.firstIndex(where: { $0.filePath == path }) {
                grouped[project]?[index].title = name
                grouped[project]?[index].named = true
            }
        }
    }

    nonisolated private static func appendSessionName(_ name: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var first = Data()
        var foundFirst = false
        while !foundFirst, let chunk = try reader.read(upToCount: 4096), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    if !first.isEmpty {
                        foundFirst = true
                        break
                    }
                } else {
                    first.append(byte)
                }
            }
        }
        var offset = try reader.seekToEnd()
        var last = Data()
        var finalByte: UInt8?
        var foundLast = false
        while offset > 0, !foundLast {
            let count = Int(min(offset, 4096))
            offset -= UInt64(count)
            try reader.seek(toOffset: offset)
            let chunk = try reader.read(upToCount: count) ?? Data()
            if finalByte == nil { finalByte = chunk.last }
            var reversed = Data()
            for byte in chunk.reversed() {
                if byte == 0x0A {
                    if !reversed.isEmpty || !last.isEmpty {
                        foundLast = true
                        break
                    }
                } else {
                    reversed.append(byte)
                }
            }
            last = Data(reversed.reversed()) + last
        }
        guard !first.isEmpty, !last.isEmpty,
              let header = try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              header["type"] as? String == "session",
              let entry = try JSONSerialization.jsonObject(with: Data(last)) as? [String: Any],
              let parentID = entry["id"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let info: [String: String] = [
            "type": "session_info", "id": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)),
            "parentId": parentID, "timestamp": timestamp.string(from: Date()), "name": name
        ]
        let encoded = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if finalByte != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
        try handle.write(contentsOf: encoded + Data([0x0A]))
    }

    func requestSessionDeletion(_ summary: SessionSummary) {
        requestSessionDeletion(
            filePath: summary.filePath,
            projectPath: summary.projectPath,
            title: summary.title
        )
    }

    func requestSessionDeletion(_ controller: SessionController) {
        guard let filePath = controller.sessionPath else {
            statusLine = "This chat has not been saved yet."
            return
        }
        requestSessionDeletion(filePath: filePath, projectPath: controller.projectPath, title: controller.title)
    }

    func deleteSession(_ request: SessionDeletionRequest) {
        sessionPendingDeletion = nil
        if let controller = controller(forSessionPath: request.filePath), controller.hasLiveWork {
            statusLine = "Cannot delete a working chat. Abort or wait for it to finish."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let url = URL(fileURLWithPath: request.filePath)
                let fileExists = await AsyncFileSystem.itemExists(at: url)
                if fileExists {
                    try await AsyncFileSystem.moveToTrash(url)
                }
                if let controller = self.controller(forSessionPath: request.filePath) {
                    self.removeController(controller, removeInbox: false)
                    if self.selectedControllerID == controller.id {
                        self.selectedControllerID = nil
                        self.selectedProjectPath = request.projectPath
                    }
                }
                let deletedInboxID = self.inboxID(forSessionPath: request.filePath)
                self.sessionInboxIDs.removeAll { $0 == deletedInboxID || self.inboxParentID(for: $0) == deletedInboxID }
                self.sessionsByProject[request.projectPath]?.removeAll { $0.filePath == request.filePath }
                self.archivedSessionsByProject[request.projectPath]?.removeAll { $0.filePath == request.filePath }
                for id in self.agentRecentSessions.keys {
                    self.agentRecentSessions[id]?.removeAll { $0.filePath == request.filePath }
                }
                let title = request.title.isEmpty ? "Untitled" : request.title
                self.statusLine = fileExists ? "Moved to Trash: \(title)" : "Closed unsaved chat: \(title)"
                self.refreshSessions()
                if self.sessionArchiveLoadState == .loaded { self.loadSessionArchive() }
            } catch {
                self.statusLine = "Could not move chat to Trash: \(error.localizedDescription)"
            }
        }
    }

    private func requestSessionDeletion(filePath: String, projectPath: String, title: String) {
        if let controller = controller(forSessionPath: filePath), controller.hasLiveWork {
            statusLine = "Cannot delete a working chat. Abort or wait for it to finish."
            return
        }
        let request = SessionDeletionRequest(
            filePath: filePath,
            projectPath: projectPath,
            title: title
        )
        sessionPendingDeletion = request
        dialog = GlowDialogRequest(
            title: "Move Chat to Trash?",
            message: "“\(request.title.isEmpty ? "Untitled" : request.title)” will be removed from PiG and moved to the Trash.",
            confirmTitle: "Move to Trash",
            role: .destructive,
            onConfirm: { [weak self] _ in self?.deleteSession(request) },
            onCancel: { [weak self] in self?.sessionPendingDeletion = nil }
        )
    }

}
