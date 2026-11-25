import XCTest
@testable import PiG

final class UsageLimitsTests: XCTestCase {
    func testAntigravitySortsFiveHourBeforeWeeklyPerGroup() {
        let groups = [
            AntigravityUsageGroup(
                name: "Gemini",
                description: "Models within this group: Gemini 3 Pro, Gemini 3 Flash.",
                buckets: [
                    AntigravityUsageBucket(window: "weekly", remainingFraction: 0.72, resetTime: nil),
                    AntigravityUsageBucket(window: "5h", remainingFraction: 0.91, resetTime: nil)
                ]
            ),
            AntigravityUsageGroup(
                name: "Claude",
                description: "Models within this group: Claude Sonnet 4, Claude Opus 4.",
                buckets: [
                    AntigravityUsageBucket(window: "weekly", remainingFraction: 0.45, resetTime: nil),
                    AntigravityUsageBucket(window: "monthly", remainingFraction: 0.80, resetTime: nil),
                    AntigravityUsageBucket(window: "5h", remainingFraction: 0.60, resetTime: nil)
                ]
            )
        ]

        let snapshot = AntigravityUsageService.makeSnapshot(groups: groups, modelName: "Claude Sonnet 4")

        XCTAssertEqual(snapshot.primary?.remainingPercent, 60)
        XCTAssertEqual(snapshot.primary?.role, .primary)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 45)
        XCTAssertEqual(snapshot.weekly?.role, .weekly)

        XCTAssertEqual(snapshot.details.map(\.label), [
            "Claude · 5h",
            "Claude · Weekly",
            "Claude · monthly",
            "Gemini · 5h",
            "Gemini · Weekly"
        ])
        XCTAssertEqual(snapshot.details.map(\.role), [.primary, .weekly, .extra, .primary, .weekly])
        XCTAssertEqual(snapshot.details.map(\.isActiveGroup), [true, true, true, false, false])
        XCTAssertEqual(snapshot.details.first?.groupSubtitle, "Claude Sonnet 4, Claude Opus 4")
    }

    func testAntigravityOverviewKeepsGroupOrderAndMarksAllActive() {
        let groups = [
            AntigravityUsageGroup(
                name: "Gemini",
                description: "Models within this group: Gemini 3 Pro.",
                buckets: [
                    AntigravityUsageBucket(window: "weekly", remainingFraction: 0.5, resetTime: nil),
                    AntigravityUsageBucket(window: "5h", remainingFraction: 0.8, resetTime: nil)
                ]
            ),
            AntigravityUsageGroup(
                name: "Claude",
                description: nil,
                buckets: [
                    AntigravityUsageBucket(window: "weekly", remainingFraction: 0.3, resetTime: nil),
                    AntigravityUsageBucket(window: "5h", remainingFraction: 0.9, resetTime: nil)
                ]
            )
        ]

        let snapshot = AntigravityUsageService.makeSnapshot(groups: groups, modelName: "")

        XCTAssertEqual(snapshot.details.map(\.label), [
            "Gemini · 5h",
            "Gemini · Weekly",
            "Claude · 5h",
            "Claude · Weekly"
        ])
        XCTAssertTrue(snapshot.details.allSatisfy(\.isActiveGroup))
    }

    func testClaudeBridgeAssignsRolesMatchingMeters() {
        let json = """
        {
          "5h-utilization": "0.2",
          "7d-utilization": "0.5",
          "7d_oi-utilization": "0.1"
        }
        """
        let snapshot = ClaudeBridgeUsageService.snapshot(from: json)
        XCTAssertEqual(snapshot?.details.map(\.label), ["5h", "Weekly", "Weekly (extra)"])
        XCTAssertEqual(snapshot?.details.map(\.role), [.primary, .weekly, .extra])
        XCTAssertEqual(snapshot?.primary?.remainingPercent, 80)
        XCTAssertEqual(snapshot?.weekly?.remainingPercent, 50)
    }

    func testConfiguredAccountsDiscovery() {
        let auth: [String: Any] = [
            "openai-codex": ["type": "oauth", "access": "tok", "accountId": "acct-1"],
            "openai-incomplete": ["type": "oauth", "access": "tok"],
            "anthropic": ["type": "oauth", "access": "tok"],
            "xai": ["type": "oauth", "access": "tok"],
            "api-only": ["type": "api_key", "access": "sk-123"]
        ]

        let all = UsageLimitProvider.configuredAccounts(
            authEntries: auth,
            claudeInstalled: true,
            antigravityInstalled: true,
            includeClaudeBridge: true
        )
        XCTAssertEqual(all, [
            .antigravityOverview,
            .codex("openai-codex"),
            .claude,
            .grok
        ])

        let claudeViaCLIOnly = UsageLimitProvider.configuredAccounts(
            authEntries: ["xai": ["type": "oauth", "access": "tok"]],
            claudeInstalled: true,
            antigravityInstalled: false,
            includeClaudeBridge: true
        )
        XCTAssertEqual(claudeViaCLIOnly, [.claude, .grok])

        let bridgeFallback = UsageLimitProvider.configuredAccounts(
            authEntries: ["xai": ["type": "oauth", "access": "tok"]],
            claudeInstalled: false,
            antigravityInstalled: false,
            includeClaudeBridge: true
        )
        XCTAssertEqual(bridgeFallback, [.claudeBridge, .grok])
    }

    func testGrokParsesOmittedZeroCreditUsagePercent() throws {
        let json = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-11-19T04:01:04.070823+00:00",
              "end": "2026-11-26T04:01:04.070823+00:00"
            },
            "onDemandCap": {"val": 0},
            "onDemandUsed": {"val": 0},
            "isUnifiedBillingUser": true,
            "billingPeriodEnd": "2026-11-26T04:01:04.070823+00:00"
          }
        }
        """
        let now = ISO8601DateFormatter().date(from: "2026-11-25T00:01:04Z")!
        let snapshot = try GrokUsageService.parseSnapshot(from: Data(json.utf8), now: now)

        XCTAssertEqual(snapshot.serviceName, "Grok")
        XCTAssertEqual(snapshot.primary?.label, "Weekly")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 100)
        XCTAssertEqual(snapshot.primary?.role, .primary)
        XCTAssertEqual(snapshot.primary?.resetText, "in 1d 4h")
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.details.count, 1)
    }

    func testGrokParsesNonZeroUsageAndExtraCap() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 37.4,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "end": "2026-11-26T04:01:04.070823+00:00"
            },
            "onDemandCap": {"val": 100},
            "onDemandUsed": {"val": 25}
          }
        }
        """
        let now = ISO8601DateFormatter().date(from: "2026-11-26T01:31:04Z")!
        let snapshot = try GrokUsageService.parseSnapshot(from: Data(json.utf8), now: now)

        XCTAssertEqual(snapshot.primary?.remainingPercent, 63)
        XCTAssertEqual(snapshot.primary?.resetText, "in 2h 30m")
        XCTAssertEqual(snapshot.weekly?.label, "Extra")
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 75)
        XCTAssertEqual(snapshot.weekly?.role, .weekly)
    }

    func testClaudeUsageParsesMissingSessionResetCleanly() throws {
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 0% used
        Current week (all models): 18% used · resets Nov 25 at 3:59am (America/Los_Angeles)
        """
        let snapshot = try ClaudeUsageService.parseSnapshot(from: output)

        XCTAssertEqual(snapshot.primary?.label, "Session")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 100)
        XCTAssertNil(snapshot.primary?.resetText)
        XCTAssertEqual(snapshot.primary?.role, .primary)
        XCTAssertEqual(snapshot.weekly?.label, "Weekly")
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 82)
        XCTAssertEqual(snapshot.weekly?.resetText, "Nov 25 at 3:59am")
        XCTAssertEqual(snapshot.weekly?.role, .weekly)
    }

    func testMeterColorsFollowRoleAndThresholds() {
        let theme = AppTheme(choice: .dusk)

        XCTAssertEqual(UsageLimitStyle.meterColor(percent: 80, role: .primary, theme: theme), theme.brass)
        XCTAssertEqual(UsageLimitStyle.meterColor(percent: 80, role: .weekly, theme: theme), theme.good)
        XCTAssertEqual(UsageLimitStyle.meterColor(percent: 25, role: .primary, theme: theme), theme.warning)
        XCTAssertEqual(UsageLimitStyle.meterColor(percent: 20, role: .weekly, theme: theme), theme.warning)
        XCTAssertEqual(UsageLimitStyle.meterColor(percent: 10, role: .primary, theme: theme), theme.danger)
        XCTAssertEqual(UsageLimitStyle.meterColor(percent: 5, role: .weekly, theme: theme), theme.danger)
        XCTAssertEqual(UsageLimitStyle.meterColor(percent: nil, role: .primary, hasError: true, theme: theme), theme.danger)
    }
}
