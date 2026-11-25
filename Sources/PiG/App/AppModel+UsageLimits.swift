import Foundation
import SwiftUI
import AppKit

extension AppModel {
    var selectedUsageLimitProvider: UsageLimitProvider? {
        if let controller = selectedController {
            return UsageLimitProvider.from(model: controller.models.first { $0.id == controller.selectedModelID })
        }
        return selectedACPController.flatMap { UsageLimitProvider.from(model: $0.activeModel) }
    }

    var latestClaudeBridgeUsage: UsageLimitSnapshot? {
        let freshest = controllers.values
            .sorted { $0.lastRuntimeUse > $1.lastRuntimeUse }
            .compactMap(\.claudeBridgeUsage)
            .first
        return freshest ?? usageLimits[.claudeBridge]
    }

    var configuredUsageAccounts: [UsageLimitProvider] {
        let hasClaudeBridge = latestClaudeBridgeUsage != nil
            || controllers.values.contains { controller in
                controller.models.contains { $0.provider.lowercased() == "claude-bridge" }
            }
            || selectableNewChatModels.contains { $0.provider.lowercased() == "claude-bridge" }
        return UsageLimitProvider.configuredAccounts(includeClaudeBridge: hasClaudeBridge)
    }

    func usageLimit(for provider: UsageLimitProvider?) -> UsageLimitSnapshot? {
        guard let provider else { return nil }
        switch provider {
        case .claudeBridge:
            return latestClaudeBridgeUsage ?? usageLimits[.claude]
        case .claude:
            return usageLimits[.claude] ?? latestClaudeBridgeUsage
        default:
            return usageLimits[provider]
        }
    }

    func refreshUsageLimit(for provider: UsageLimitProvider?, force: Bool = false) {
        guard let provider, provider != .claudeBridge else { return }
        Task { [weak self] in
            await self?.fetchUsageLimit(for: provider, force: force)
        }
    }

    func fetchUsageLimit(for provider: UsageLimitProvider, force: Bool = false) async {
        guard provider != .claudeBridge else {
            if let bridge = latestClaudeBridgeUsage {
                usageLimits[.claudeBridge] = bridge
                usageLimitFetchDates[.claudeBridge] = Date()
            }
            return
        }
        usageLimitStore.refreshing.insert(provider)
        defer { usageLimitStore.refreshing.remove(provider) }

        _ = await PiEnvironment.mergedAsync()
        let snapshot = await UsageLimitService.fetch(provider, forceRefresh: force)
        let now = Date()
        usageLimits[provider] = snapshot
        usageLimitFetchDates[provider] = now

        if case .antigravity = provider {
            let related = Set(usageLimits.keys + [.antigravityOverview]).filter { key in
                if case .antigravity = key, key != provider { return true }
                return false
            }
            for other in related {
                let updated = await UsageLimitService.fetch(other, forceRefresh: false)
                usageLimits[other] = updated
                usageLimitFetchDates[other] = now
            }
        }
    }

    func refreshAllConfiguredUsageLimits(force: Bool = false) async {
        _ = await PiEnvironment.mergedAsync()
        let accounts = configuredUsageAccounts
        let now = Date()
        let toFetch = accounts.filter { provider in
            if provider == .claudeBridge { return true }
            if force { return true }
            guard let lastFetch = usageLimitFetchDates[provider], usageLimits[provider] != nil else { return true }
            return now.timeIntervalSince(lastFetch) >= 60
        }
        await withTaskGroup(of: Void.self) { group in
            for provider in toFetch {
                group.addTask { [weak self] in
                    await self?.fetchUsageLimit(for: provider, force: force)
                }
            }
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
                        await self?.fetchUsageLimit(for: provider, force: false)
                        guard !Task.isCancelled else { break }
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
