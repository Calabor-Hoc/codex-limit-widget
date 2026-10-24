import Foundation
import XCTest
@testable import Codex_Limit_Widget

final class CodexLimitWidgetTests: XCTestCase {
    func testZeroUsageStableResetAdvancesAndNextExpiryRollsAfterRestart() throws {
        let start = Date(timeIntervalSince1970: 180000)
        let old = start.addingTimeInterval(-61)
        let reset = start.addingTimeInterval(18000)
        var sample = snapshot(updatedAt: start)
        sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 0, windowDurationMins: 300, resetsAt: reset)
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 0, windowDurationMins: 10080, resetsAt: start.addingTimeInterval(604800))
        let oldKey = "5H:\(Int(old.timeIntervalSince1970 / 60))"
        var state = ResetRollingState(boundaries: ["5H": old], attempted: [oldKey], lastAttempt: start)
        state.observe(sample, now: start)
        state.observe(sample, now: start.addingTimeInterval(30)) // cached reading is not new evidence
        XCTAssertEqual(state.resetEvidence?["5H"]?.samples, 1)
        sample.updatedAt = start.addingTimeInterval(30)
        state.observe(sample, now: sample.updatedAt)
        state = try JSONDecoder().decode(ResetRollingState.self, from: JSONEncoder().encode(state))
        sample.updatedAt = start.addingTimeInterval(60)
        state.observe(sample, now: sample.updatedAt)
        XCTAssertEqual(state.boundaries["5H"], reset)
        XCTAssertTrue(state.dueOpportunities(sample, now: sample.updatedAt).isEmpty)
        XCTAssertTrue(state.attempted.contains(oldKey))
        sample.updatedAt = reset.addingTimeInterval(61)
        state.observe(sample, now: sample.updatedAt)
        XCTAssertEqual(state.dueOpportunities(sample, now: sample.updatedAt), ["5H:\(Int(reset.timeIntervalSince1970 / 60))"])
    }

    func testSlidingZeroResetAndStaleReadingsCannotConfirm() {
        let start = Date(timeIntervalSince1970: 180000)
        let old = start.addingTimeInterval(-61)
        var state = ResetRollingState(boundaries: ["5H": old, "WEEK": old])
        var sample = snapshot(updatedAt: start)
        for step in 0...5 {
            sample.updatedAt = start.addingTimeInterval(Double(step * 30))
            sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 0, windowDurationMins: 300, resetsAt: sample.updatedAt.addingTimeInterval(18000))
            sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 0, windowDurationMins: 10080, resetsAt: sample.updatedAt.addingTimeInterval(604800))
            state.observe(sample, now: sample.updatedAt)
        }
        XCTAssertEqual(state.boundaries, ["5H": old, "WEEK": old])
        state.observe(sample, now: sample.updatedAt.addingTimeInterval(91))
        XCTAssertNil(state.resetEvidence)
    }

    func testWeeklyStableZeroResetAndLongGapRestartEvidence() {
        let start = Date(timeIntervalSince1970: 180000)
        let old = start.addingTimeInterval(-61)
        let reset = start.addingTimeInterval(604800)
        var state = ResetRollingState(boundaries: ["WEEK": old])
        var sample = snapshot(updatedAt: start)
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 0, windowDurationMins: 10080, resetsAt: reset)
        for offset in [0, 30, 1000, 1030] {
            sample.updatedAt = start.addingTimeInterval(Double(offset))
            state.observe(sample, now: sample.updatedAt)
        }
        XCTAssertEqual(state.boundaries["WEEK"], old)
        sample.updatedAt = start.addingTimeInterval(1060)
        state.observe(sample, now: sample.updatedAt)
        XCTAssertEqual(state.boundaries["WEEK"], reset)
    }

    func testLegacyRollingStateStillLoads() throws {
        let state = try JSONDecoder().decode(ResetRollingState.self, from: Data("{\"boundaries\":{},\"attempted\":[]}".utf8))
        XCTAssertNil(state.resetEvidence)
    }

    func testTargetValidationRoundsBeforeCheckingLeadTime() {
        let now = Date(timeIntervalSince1970: 125)
        XCTAssertNil(ResetTargetSchedule.validatedTarget(now.addingTimeInterval(18000), now: now))
        XCTAssertEqual(ResetTargetSchedule.validatedTarget(now.addingTimeInterval(18060), now: now),
                       Date(timeIntervalSince1970: 18180))
        XCTAssertNil(ResetTargetSchedule.validatedTarget(now, now: now))
    }

    func testFutureDatedUsageCannotAuthorizeRolling() {
        let now = Date()
        var sample = snapshot(updatedAt: now.addingTimeInterval(1))
        sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 0, windowDurationMins: 300, resetsAt: now.addingTimeInterval(-61))
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 20, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400))
        let state = ResetRollingState(boundaries: ["5H": now.addingTimeInterval(-61)])
        XCTAssertTrue(state.dueOpportunities(sample, now: now).isEmpty)
        sample.updatedAt = now
        XCTAssertEqual(state.dueOpportunities(sample, now: now).count, 1)
    }

    func testSyncTimelineCoversEveryLabelChangeWithoutRedundantViews() {
        let sync = Date(timeIntervalSince1970: 0)
        let dates = LimitSyncTimeText.timelineDates(syncedAt: sync, now: sync)
        XCTAssertEqual(dates.count, 142)
        var entry = 0
        for second in 0...32402 {
            let now = sync.addingTimeInterval(Double(second))
            while entry + 1 < dates.count && dates[entry + 1] <= now { entry += 1 }
            XCTAssertEqual(LimitSyncTimeText.make(for: sync, now: dates[entry]),
                           LimitSyncTimeText.make(for: sync, now: now))
        }
        let old = sync.addingTimeInterval(40000)
        XCTAssertEqual(LimitSyncTimeText.timelineDates(syncedAt: sync, now: old), [old])
        XCTAssertEqual(LimitSyncTimeText.timelineDates(syncedAt: nil, now: sync), [sync])
        let midMinute = sync.addingTimeInterval(125)
        let partial = LimitSyncTimeText.timelineDates(syncedAt: sync, now: midMinute)
        XCTAssertEqual(partial[0], midMinute)
        XCTAssertEqual(partial[1], sync.addingTimeInterval(180))
    }

    func testNextResetScheduleHoldsOvernightAndCatchesUpOnceAwake() throws {
        let formatter = ISO8601DateFormatter()
        let target = try XCTUnwrap(formatter.date(from: "2026-10-23T11:00:00+08:00"))
        let schedule = ResetTargetSchedule(target: target)
        for (stamp, allowed, phase) in [
            ("2026-10-22T23:30:00+08:00", true, "continuous_before_pause"),
            ("2026-10-23T00:59:59+08:00", true, "continuous_before_pause"),
            ("2026-10-23T01:00:00+08:00", false, "holding_for_target"),
            ("2026-10-23T03:00:00+08:00", false, "holding_for_target"),
            ("2026-10-23T05:59:59+08:00", false, "holding_for_target"),
            ("2026-10-23T06:00:00+08:00", true, "target_start_due"),
            ("2026-10-23T09:00:00+08:00", true, "target_start_due"),
            ("2026-10-23T11:00:00+08:00", true, "target_elapsed")
        ] {
            let now = try XCTUnwrap(formatter.date(from: stamp))
            XCTAssertEqual(schedule.allowsRolling(at: now), allowed, stamp)
            XCTAssertEqual(schedule.phase(at: now), phase, stamp)
        }
        var preferences = LimitPreferences.default
        preferences.nextFiveHourResetTarget = target
        let restored = try JSONDecoder().decode(LimitPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.nextFiveHourResetTarget, target)
        XCTAssertNil(try JSONDecoder().decode(LimitPreferences.self, from: Data("{}".utf8)).nextFiveHourResetTarget)
    }

    func testRolloverWaitsForBoundaryAndBufferAndDoesNotDuplicate() {
        let now = Date()
        let end = now.addingTimeInterval(-61)
        var sample = snapshot(updatedAt: now)
        sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 0, windowDurationMins: 300, resetsAt: now.addingTimeInterval(18000))
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 20, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400))
        var state = ResetRollingState(boundaries: ["5H": end])
        state.observe(sample, now: now)
        let keys = state.dueOpportunities(sample, now: now)
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(state.dueOpportunities(sample, now: end.addingTimeInterval(59)).isEmpty)
        state.attempted.formUnion(keys)
        XCTAssertTrue(state.dueOpportunities(sample, now: now).isEmpty)
    }

    func testScheduledHoldAlsoBlocksWeeklyRequestsAndActiveWindowConflicts() {
        let target = Date(timeIntervalSince1970: 180000)
        let start = target.addingTimeInterval(-18000)
        var state = ResetRollingState(boundaries: ["5H": start.addingTimeInterval(-10800), "WEEK": start.addingTimeInterval(-7200)])
        var sample = snapshot(updatedAt: start.addingTimeInterval(-3600))
        sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 0, windowDurationMins: 300, resetsAt: target)
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 0, windowDurationMins: 10080, resetsAt: target)
        XCTAssertTrue(state.dueOpportunities(sample, now: sample.updatedAt, target: target).isEmpty)
        sample.updatedAt = start
        let keys = state.dueOpportunities(sample, now: start, target: target)
        XCTAssertEqual(keys.count, 2)
        sample.fiveHour?.usedPercent = 1
        XCTAssertTrue(state.dueOpportunities(sample, now: start, target: target).isEmpty)
        sample.fiveHour?.usedPercent = 0
        state.attempted.formUnion(keys)
        XCTAssertTrue(state.dueOpportunities(sample, now: start, target: target).isEmpty)
    }

    func testRolloverDoesNotSendForAlreadyActiveWindowOrExhaustedWeeklyQuota() {
        let now = Date()
        var sample = snapshot(updatedAt: now)
        sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 1, windowDurationMins: 300, resetsAt: now.addingTimeInterval(18000))
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 20, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400))
        var state = ResetRollingState(boundaries: ["5H": now.addingTimeInterval(-61)])
        state.observe(sample, now: now)
        XCTAssertTrue(state.dueOpportunities(sample, now: now).isEmpty)
        state.boundaries["5H"] = now.addingTimeInterval(-61)
        sample.weekly?.usedPercent = 99
        XCTAssertTrue(state.dueOpportunities(sample, now: now).isEmpty)
        sample.weekly?.usedPercent = 20
        state.lastAttempt = now.addingTimeInterval(-120)
        XCTAssertTrue(state.dueOpportunities(sample, now: now).isEmpty)
    }

    func testRolloverReservationSurvivesEncoding() throws {
        var state = ResetRollingState(boundaries: ["WEEK": Date(timeIntervalSince1970: 100)])
        state.attempted.insert("WEEK:1")
        let decoded = try JSONDecoder().decode(ResetRollingState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.attempted, state.attempted)
        XCTAssertEqual(decoded.boundaries, state.boundaries)
    }

    func testRolloverCombinesDueWindowsAndRejectsStaleEvidence() {
        let now = Date()
        let end = now.addingTimeInterval(-61)
        var sample = snapshot(updatedAt: now)
        sample.fiveHour = LimitWindowSnapshot(label: "5H", usedPercent: 0, windowDurationMins: 300, resetsAt: end)
        sample.weekly = LimitWindowSnapshot(label: "Week", usedPercent: 0, windowDurationMins: 10080, resetsAt: end)
        var state = ResetRollingState()
        state.observe(sample, now: now)
        XCTAssertEqual(state.dueOpportunities(sample, now: now).count, 2)
        sample.updatedAt = now.addingTimeInterval(-91)
        XCTAssertTrue(state.dueOpportunities(sample, now: now).isEmpty)
    }
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func snapshot(updatedAt: Date) -> LimitSnapshot {
        LimitSnapshot(
            fiveHour: nil,
            weekly: nil,
            credits: nil,
            planType: nil,
            usage: nil,
            updatedAt: updatedAt,
            errorMessage: nil
        )
    }

    private func usage(_ days: [DailyTokenUsage]) -> AccountUsageSnapshot {
        AccountUsageSnapshot(
            dailyTokens: days,
            lifetimeTokens: nil,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            learnedSkillsCount: nil,
            totalSkillUses: nil,
            totalThreads: nil,
            lastDailyTokens: nil,
            lastDailyDate: nil,
            updatedAt: nil
        )
    }

    func testRemainingLevelBelowCriticalBoundary() {
        XCTAssertEqual(LimitRemainingLevel.resolve(remainingPercent: 19), .critical)
    }

    func testRemainingLevelAtCriticalBoundary() {
        XCTAssertEqual(LimitRemainingLevel.resolve(remainingPercent: 20), .warning)
    }

    func testRemainingLevelBelowWarningBoundary() {
        XCTAssertEqual(LimitRemainingLevel.resolve(remainingPercent: 49), .warning)
    }

    func testRemainingLevelAtWarningBoundary() {
        XCTAssertEqual(LimitRemainingLevel.resolve(remainingPercent: 50), .normal)
    }

    func testRemainingLevelAtZero() {
        XCTAssertEqual(LimitRemainingLevel.resolve(remainingPercent: 0), .critical)
    }

    func testRecentSnapshotIsNotStale() {
        XCTAssertFalse(snapshot(updatedAt: Date().addingTimeInterval(-299)).isStale)
    }

    func testOldSnapshotIsStale() {
        XCTAssertTrue(snapshot(updatedAt: Date().addingTimeInterval(-301)).isStale)
    }

    func testTokenCountBelowThousand() {
        XCTAssertEqual(TokenCountText.make(999), "999")
    }

    func testTokenCountAtThousand() {
        XCTAssertEqual(TokenCountText.make(1_000), "1.0K")
    }

    func testTokenCountInMillions() {
        XCTAssertEqual(TokenCountText.make(820_100_000), "820.1M")
    }

    func testTokenCountInBillions() {
        XCTAssertEqual(TokenCountText.make(16_380_000_000), "16.38B")
    }

    func testTokenCountAbsent() {
        XCTAssertEqual(TokenCountText.make(nil), "--")
    }

    func testResetClockFormatsHoursAndMinutes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 7, minute: 5))!
        XCTAssertEqual(LimitResetClockText.make(for: date), "07:05")
    }

    func testResetClockWithoutDate() {
        XCTAssertEqual(LimitResetClockText.make(for: nil), "--")
    }

    func testWeeklyResetIncludesWeekdayAnd24HourMinuteTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 19, minute: 5))!
        let window = LimitWindowSnapshot(label: "Weekly", usedPercent: 48, windowDurationMins: 10_080, resetsAt: date)
        XCTAssertEqual(window.resetWeekdayText(locale: Locale(identifier: "en_US")), "Sat 19:05")
    }

    func testSyncAgeBoundaries() {
        let date = Date(timeIntervalSince1970: 0)
        for (seconds, expected) in [(0.0, "0min ago"), (60, "1min ago"), (120, "2min ago"),
                                    (3599, "59min ago"), (3600, "1h ago"), (5400, "1.5h ago"),
                                    (32400, "9h ago"), (32401, "stale"), (-60, "0min ago")] {
            XCTAssertEqual(LimitSyncTimeText.make(for: date, now: date.addingTimeInterval(seconds)), expected)
        }
    }

    @MainActor func testPowerAwarePollingIntervals() {
        XCTAssertEqual(LimitViewModel.pollingInterval(onACPower: true), 30)
        XCTAssertEqual(LimitViewModel.pollingInterval(onACPower: false), 300)
    }

    func testRateLimitsFixtureUsesCodexLimitsAndNormalizesWindows() throws {
        let result = try JSONDecoder().decode(RateLimitsEnvelope.self, from: fixture("rate-limits")).result
        let normalized = try result.normalizedSnapshot(usage: nil)
        XCTAssertEqual(normalized.fiveHour?.usedPercent, 25)
        XCTAssertEqual(normalized.weekly?.usedPercent, 70)
        XCTAssertEqual(normalized.fiveHour?.windowDurationMins, 300)
        XCTAssertEqual(normalized.weekly?.windowDurationMins, 10_080)
        XCTAssertEqual(normalized.planType, "pro")
        XCTAssertEqual(normalized.credits?.balance, "12.5")
    }

    func testUsageFixtureDecodesAliasesAndDailyBuckets() throws {
        let result = try JSONDecoder().decode(AccountUsageEnvelope.self, from: fixture("usage-read")).result
        let normalized = result.normalizedUsage()
        XCTAssertEqual(normalized.lifetimeTokens, 5_400)
        XCTAssertEqual(normalized.learnedSkillsCount, 4)
        XCTAssertEqual(normalized.totalSkillUses, 12)
        XCTAssertEqual(normalized.totalThreads, 6)
        XCTAssertEqual(normalized.dailyTokens?.count, 2)
        XCTAssertEqual(normalized.lastDailyDate, "2026-09-26")
        XCTAssertEqual(normalized.lastDailyTokens, 3_200)
        XCTAssertNotNil(normalized.updatedAt)
    }

    func testLegacySnapshotWithoutUsageTimestampDecodesAsExpired() throws {
        let legacy = try JSONDecoder().decode(LimitSnapshot.self, from: fixture("legacy-snapshot"))
        XCTAssertEqual(legacy.usage?.lifetimeTokens, 1_000)
        XCTAssertNil(legacy.usage?.updatedAt)
        XCTAssertTrue(try XCTUnwrap(legacy.usage).isStale)
        XCTAssertNil(legacy.freshUsage)
    }

    func testPreferencesFromOlderVersionEnableColoredMeter() throws {
        let stored = Data(#"{"menuBarMode":"percentOnly","showsMenuBarItem":true}"#.utf8)
        let preferences = try JSONDecoder().decode(LimitPreferences.self, from: stored)
        XCTAssertTrue(preferences.menuBarColoredMeter)
        XCTAssertFalse(preferences.menuBarColoredDigits)
    }

    func testDisabledColoredMeterStaysDisabled() throws {
        let stored = Data(#"{"menuBarColoredMeter":false}"#.utf8)
        let preferences = try JSONDecoder().decode(LimitPreferences.self, from: stored)
        XCTAssertFalse(preferences.menuBarColoredMeter)
    }

    func testSystemDesignResolvesToDark() {
        XCTAssertEqual(MenuWindowDesign.system.resolved(isDark: true), .terminal)
    }

    func testSystemDesignResolvesToLight() {
        XCTAssertEqual(MenuWindowDesign.system.resolved(isDark: false), .editorial)
    }

    func testExplicitDesignRemainsSelected() {
        XCTAssertEqual(MenuWindowDesign.editorial.resolved(isDark: true), .editorial)
        XCTAssertEqual(MenuWindowDesign.terminal.resolved(isDark: false), .terminal)
    }

    func testSevenDayAverageWithoutBuckets() {
        XCTAssertNil(usage([]).sevenDayAverageTokens)
    }

    func testSevenDayAverageSkipsMissingTokens() {
        let reading = usage([
            DailyTokenUsage(date: "2026-09-24", tokens: 300),
            DailyTokenUsage(date: "2026-09-25", tokens: nil),
            DailyTokenUsage(date: "2026-09-26", tokens: 100)
        ])
        XCTAssertEqual(reading.sevenDayAverageTokens, 200)
    }

    func testSevenDayAverageIncludesZeroTokens() {
        let reading = usage([
            DailyTokenUsage(date: "2026-09-25", tokens: 0),
            DailyTokenUsage(date: "2026-09-26", tokens: 100)
        ])
        XCTAssertEqual(reading.sevenDayAverageTokens, 50)
    }
}
