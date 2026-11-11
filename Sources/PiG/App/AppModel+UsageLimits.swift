import Foundation
import SwiftUI
import AppKit

extension AppModel {
    var selectedUsageLimitProvider: UsageLimitProvider? {
        guard let controller = selectedController else { return nil }
        let selectedModel = controller.models.first { $0.id == controller.selectedModelID }
        return UsageLimitProvider.from(model: selectedModel)
    }

    func usageLimit(for provider: UsageLimitProvider?) -> UsageLimitSnapshot? {
        guard let provider else { return nil }
        return usageLimits[provider]
    }

    func refreshUsageLimit(for provider: UsageLimitProvider?) {
        guard let provider, provider != .claudeBridge else { return }
        Task { [weak self] in
            _ = await PiEnvironment.mergedAsync()
            let snapshot = await UsageLimitService.fetch(provider)
            self?.usageLimits[provider] = snapshot
            self?.usageLimitFetchDates[provider] = Date()
        }
    }

    func startUsageLimitPolling() {
        if usageLimitActivationObserver == nil {
            usageLimitActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.startUsageLimitPolling() }
            }
            usageLimitDeactivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.usageLimitTask?.cancel()
                    self?.usageLimitTask = nil
                }
            }
        }
        usageLimitTask?.cancel()
        usageLimitTask = nil
        guard NSApplication.shared.isActive else { return }
        usageLimitTask = Task { [weak self] in
            _ = await PiEnvironment.mergedAsync()
            while !Task.isCancelled {
                if let provider = self?.selectedUsageLimitProvider, provider != .claudeBridge {
                    let elapsed = self?.usageLimitFetchDates[provider].map { Date().timeIntervalSince($0) } ?? 300
                    if elapsed >= 300 {
                        let snapshot = await UsageLimitService.fetch(provider)
                        guard !Task.isCancelled else { break }
                        self?.usageLimits[provider] = snapshot
                        self?.usageLimitFetchDates[provider] = Date()
                    }
                    let delay = elapsed >= 300 ? 300 : 300 - elapsed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
    }

}
