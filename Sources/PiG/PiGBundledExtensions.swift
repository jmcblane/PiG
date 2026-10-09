import Foundation

// Only chat-session processes receive these extensions. Nothing is copied into
// pi's agent directory or added to its persistent settings.
enum PiGBundledExtensions {
    static func addingTo(_ resources: PiLaunchResources) throws -> PiLaunchResources {
        guard HTMLRenderPreference.isEnabled else { return resources }
        let extensionURL: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "html-render", withExtension: "ts", subdirectory: "extensions") else {
                throw PiRPCClient.RPCError.launchFailed("PiG's bundled HTML extension is missing. Rebuild the app.")
            }
            extensionURL = url
        } else {
            // swift run / swift test do not use the app bundle assembled by the
            // build script. Resolve the checked-in resource from this source file.
            extensionURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/extensions/html-render.ts")
        }
        guard FileManager.default.isReadableFile(atPath: extensionURL.path) else {
            throw PiRPCClient.RPCError.launchFailed("PiG's HTML extension could not be found at \(extensionURL.path).")
        }
        var result = resources
        if !result.extensions.contains(extensionURL.path) {
            result.extensions.append(extensionURL.path)
        }
        return result
    }
}
