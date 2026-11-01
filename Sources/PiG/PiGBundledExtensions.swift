import Foundation

// Only chat-session processes receive these extensions. Nothing is copied into
// pi's agent directory or added to its persistent settings.
enum PiGBundledExtensions {
    static func addingTo(_ resources: PiLaunchResources) throws -> PiLaunchResources {
        let names = ["claude-usage"] + (HTMLRenderPreference.isEnabled ? ["html-render"] : [])
        var result = resources
        for name in names {
            let extensionURL = try bundledExtension(named: name)
            if !result.extensions.contains(extensionURL.path) {
                result.extensions.append(extensionURL.path)
            }
        }
        return result
    }

    private static func bundledExtension(named name: String) throws -> URL {
        let extensionURL: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ts", subdirectory: "extensions") else {
                throw PiRPCClient.RPCError.launchFailed("PiG's bundled \(name) extension is missing. Rebuild the app.")
            }
            extensionURL = url
        } else {
            // swift run / swift test do not use the app bundle assembled by the
            // build script. Resolve the checked-in resource from this source file.
            extensionURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/extensions/\(name).ts")
        }
        guard FileManager.default.isReadableFile(atPath: extensionURL.path) else {
            throw PiRPCClient.RPCError.launchFailed("PiG's \(name) extension could not be found at \(extensionURL.path).")
        }
        return extensionURL
    }
}
