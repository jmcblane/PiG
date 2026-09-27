import AppKit

@MainActor
enum ProjectDialogs {
    static func chooseProjectDirectories() async -> [URL] {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Add"
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
        }
    }

    static func createProjectDirectoryURL() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.title = "Create Project Directory"
            panel.prompt = "Create"
            panel.nameFieldStringValue = "NewProject"
            panel.canCreateDirectories = true
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
