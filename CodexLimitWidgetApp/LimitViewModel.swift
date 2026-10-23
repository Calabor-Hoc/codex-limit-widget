import Foundation
import Network
import os
import ServiceManagement
@preconcurrency import UserNotifications
import WidgetKit
import IOKit.ps

enum LoginItemRegistrationPolicy {
    static let canonicalBundleIdentifier = "com.calaborhoc.CodexLimitWidgetCustom"
    static let canonicalApplicationPath = "/Applications/Maestro Limit.app"

    static func shouldRegister(bundleIdentifier: String?, bundleURL: URL, isDebugBuild: Bool) -> Bool {
        guard !isDebugBuild,
              bundleIdentifier == canonicalBundleIdentifier
        else { return false }

        let canonicalURL = URL(fileURLWithPath: canonicalApplicationPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidateURL = bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()

        return candidateURL.path == canonicalURL.path
    }
}

/// Persisted opportunities are independent of app restarts and model results.
struct ResetRollingState: Codable {
    var boundaries: [String: Date] = [:]
    var attempted: Set<String> = []
    var lastAttempt: Date?

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexLimitWidgetCustom/reset-rolling-state.json")
    }

    static func load() -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        // A damaged reservation file must fail closed instead of duplicating a send.
        return (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)))
            ?? Self(lastAttempt: .distantFuture)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }

    mutating func observe(_ snapshot: LimitSnapshot, now: Date) {
        for (name, window) in [("5H", snapshot.fiveHour), ("WEEK", snapshot.weekly)] {
            guard let window, let reset = window.resetsAt else { continue }
            if let existing = boundaries[name] {
                // New actual usage has already anchored the next window. No ping
                // is needed; an advancing zero-usage clock is not confirmation.
                if reset.timeIntervalSince(existing) > 60 && window.usedPercent > 0 && reset > now {
                    boundaries[name] = reset
                }
            } else if window.usedPercent > 0 || reset <= now {
                boundaries[name] = reset
            }
        }
    }

    func dueOpportunities(_ snapshot: LimitSnapshot, now: Date, target: Date? = nil) -> [String] {
        if let target {
            let schedule = ResetTargetSchedule(target: target)
            guard schedule.allowsRolling(at: now) else { return [] }
            if schedule.phase(at: now) == "target_start_due",
               (snapshot.fiveHour?.usedPercent ?? 0) > 0,
               (snapshot.fiveHour?.resetsAt ?? .distantPast) > now { return [] }
        }
        guard (0..<90).contains(now.timeIntervalSince(snapshot.updatedAt)),
              let weekly = snapshot.weekly, weekly.usedPercent < 99,
              (snapshot.fiveHour?.usedPercent ?? 0) < 100,
              lastAttempt.map({ now.timeIntervalSince($0) >= 3600 }) ?? true else { return [] }
        return boundaries.sorted { $0.key < $1.key }.compactMap { name, reset in
            let window = name == "5H" ? snapshot.fiveHour : snapshot.weekly
            guard window != nil, now.timeIntervalSince(reset) >= 60 else { return nil }
            let key = "\(name):\(Int(reset.timeIntervalSince1970 / 60))"
            return attempted.contains(key) ? nil : key
        }
    }
}

@MainActor
final class LimitViewModel: ObservableObject {
    @Published private(set) var snapshot: LimitSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isInstallingCLI = false
    @Published private(set) var connectionState: CodexConnectionState = .checking
    @Published private(set) var connectionMessage: String?
    @Published private(set) var preferences: LimitPreferences
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastCLIErrorMessage: String?
    @Published private(set) var lastCLIErrorAt: Date?

    private let client = CodexRateLimitClient()
    private let widgetBridge = LoopbackWidgetBridge()
    private let lowLimitNotificationManager = LowLimitNotificationManager()
    private let notificationSetupKey = "systemNotificationsConfigured"
    private let loginItemSetupKey = "loginItemRegistrationCompleted"
    private var timer: Timer?
    private var started = false
    private var lastAutomaticRefreshAt: Date?
    private var lastObservedPowerSource: String?
    private var rollingState = ResetRollingState.load()
    private var isStartingResetWindow = false

    private func recordPollingEvent(_ event: String, source: String, interval: TimeInterval, extra: [String: Any] = [:]) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexLimitWidgetCustom/polling-logs", isDirectory: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
        let url = directory.appendingPathComponent("polling-\(stamp.prefix(10)).jsonl")
        var record: [String: Any] = ["timestamp": stamp, "event": event, "powerSource": source,
                                     "intervalSeconds": interval, "pid": ProcessInfo.processInfo.processIdentifier,
                                     "app": "Maestro Limit", "logSchema": 2,
                                     "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        record.merge(extra) { _, new in new }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch {
            LimitLog.store.error("Polling audit log failed: \(error.localizedDescription)")
        }
    }

    static func pollingInterval(onACPower: Bool) -> TimeInterval {
        onACPower ? 30 : 300
    }

    private func automaticRefreshIfDue() async {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let interval = Self.pollingInterval(onACPower: source == kIOPSACPowerValue)
        let powerSource = source ?? "unknown"
        if lastObservedPowerSource != powerSource {
            recordPollingEvent("power_source_changed", source: powerSource, interval: interval,
                               extra: ["previousPowerSource": lastObservedPowerSource ?? "startup"])
            lastObservedPowerSource = powerSource
        }
        let elapsed = lastAutomaticRefreshAt.map { Date().timeIntervalSince($0) }
        // Timer delivery has subsecond jitter; don't defer a due poll by a
        // whole additional tick because it arrived a few milliseconds early.
        guard elapsed.map({ $0 >= interval - 0.5 }) ?? true else {
            recordPollingEvent("waiting", source: powerSource, interval: interval,
                               extra: ["elapsedSinceAttemptSeconds": elapsed ?? 0])
            return
        }
        guard !isRefreshing, !isAuthenticating, !isInstallingCLI else {
            recordPollingEvent("skipped_busy", source: powerSource, interval: interval)
            return
        }
        lastAutomaticRefreshAt = Date()
        let startedAt = Date()
        let previousSync = lastSuccessfulSyncAt
        recordPollingEvent("refresh_started", source: powerSource, interval: interval,
                           extra: ["elapsedSinceAttemptSeconds": elapsed ?? 0])
        await refresh()
        var result: [String: Any] = ["durationSeconds": Date().timeIntervalSince(startedAt),
                                     "succeeded": lastSuccessfulSyncAt != previousSync]
        if let lastSuccessfulSyncAt {
            result["lastSuccessfulSyncAt"] = ISO8601DateFormatter().string(from: lastSuccessfulSyncAt)
        }
        if let lastCLIErrorMessage { result["error"] = lastCLIErrorMessage }
        recordPollingEvent("refresh_finished", source: powerSource, interval: interval, extra: result)
        if lastSuccessfulSyncAt != previousSync {
            await keepResetWindowsRolling()
        }
    }

    private func keepResetWindowsRolling() async {
        guard let snapshot, !isStartingResetWindow else { return }
        let now = Date()
        rollingState.observe(snapshot, now: now)
        do { try rollingState.save() } catch {
            recordPollingEvent("rollover_state_save_failed", source: "unknown", interval: 30)
            return
        }
        let schedule = preferences.nextFiveHourResetTarget.map { ResetTargetSchedule(target: $0) }
        let holding = schedule.map { !$0.allowsRolling(at: now) } ?? false
        let activeAtScheduledStart = schedule?.phase(at: now) == "target_start_due"
            && (snapshot.fiveHour?.usedPercent ?? 0) > 0
            && (snapshot.fiveHour?.resetsAt ?? .distantPast) > now
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let power = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? ?? "unknown"
        let keys = rollingState.dueOpportunities(snapshot, now: now, target: schedule?.target)
        let reason = !preferences.keepsResetWindowsRolling ? "disabled"
            : power != kIOPSACPowerValue ? "not_on_ac_power"
            : holding ? "holding_for_target"
            : activeAtScheduledStart ? "five_hour_window_already_active"
            : keys.isEmpty ? "no_eligible_opportunity" : "eligible"
        let dates = rollingState.boundaries.mapValues { ISO8601DateFormatter().string(from: $0) }
        var decision: [String: Any] = ["reason": reason, "enabled": preferences.keepsResetWindowsRolling,
                                      "opportunities": keys, "trackedResetTimes": dates,
                                      "reservedCount": rollingState.attempted.count,
                                      "snapshotUpdatedAt": ISO8601DateFormatter().string(from: snapshot.updatedAt)]
        decision["fiveHourUsedPercent"] = snapshot.fiveHour?.usedPercent
        decision["weeklyUsedPercent"] = snapshot.weekly?.usedPercent
        if let reset = snapshot.fiveHour?.resetsAt { decision["observedFiveHourReset"] = ISO8601DateFormatter().string(from: reset) }
        if let reset = snapshot.weekly?.resetsAt { decision["observedWeeklyReset"] = ISO8601DateFormatter().string(from: reset) }
        if let attempt = rollingState.lastAttempt { decision["lastAttemptAt"] = ISO8601DateFormatter().string(from: attempt) }
        if let schedule {
            decision["scheduleTarget"] = ISO8601DateFormatter().string(from: schedule.target)
            decision["schedulePauseAt"] = ISO8601DateFormatter().string(from: schedule.pauseAt)
            decision["scheduleStartAt"] = ISO8601DateFormatter().string(from: schedule.startAt)
            decision["schedulePhase"] = schedule.phase(at: now)
            decision["secondsPastScheduledStart"] = max(0, now.timeIntervalSince(schedule.startAt))
            if let reset = snapshot.fiveHour?.resetsAt {
                decision["observedResetOffsetFromTargetSeconds"] = reset.timeIntervalSince(schedule.target)
            }
        }
        recordPollingEvent("rollover_decision", source: power, interval: Self.pollingInterval(onACPower: power == kIOPSACPowerValue), extra: decision)
        guard preferences.keepsResetWindowsRolling, power == kIOPSACPowerValue else { return }
        guard !holding, !activeAtScheduledStart else { return }
        guard !keys.isEmpty else { return }
        isStartingResetWindow = true
        defer { isStartingResetWindow = false }
        let executionStartedAt = Date()
        var sendAttempted = false
        do {
            let cli = try CodexCLI.resolve()
            recordPollingEvent("rollover_model_probe_started", source: power, interval: 30, extra: ["opportunities": keys])
            guard let model = try await cli.resetWindowModel() else {
                recordPollingEvent("rollover_no_supported_model", source: "AC Power", interval: 30,
                                   extra: ["opportunities": keys])
                return
            }
            let latestPower = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            guard preferences.keepsResetWindowsRolling,
                  preferences.nextFiveHourResetTarget == schedule?.target,
                  schedule?.allowsRolling(at: Date()) ?? true,
                  IOPSGetProvidingPowerSourceType(latestPower)?.takeUnretainedValue() as String? == kIOPSACPowerValue else {
                recordPollingEvent("rollover_cancelled_before_send", source: "unknown", interval: 30,
                                   extra: ["reason": "power_enable_or_schedule_changed"])
                return
            }
            // The read-only model probe can take time. Revalidate fresh usage,
            // then persist a reservation only when a send is actually possible.
            let sendTime = Date()
            guard let latest = self.snapshot else { return }
            rollingState.observe(latest, now: sendTime)
            let currentKeys = rollingState.dueOpportunities(latest, now: sendTime, target: schedule?.target)
            guard keys.allSatisfy(currentKeys.contains) else {
                recordPollingEvent("rollover_cancelled_before_send", source: "AC Power", interval: 30,
                                   extra: ["reason": "usage_changed_or_stale"])
                return
            }
            var reserved = rollingState
            reserved.attempted.formUnion(keys)
            reserved.lastAttempt = sendTime
            do { try reserved.save() } catch {
                recordPollingEvent("rollover_reservation_failed", source: "AC Power", interval: 30)
                return
            }
            rollingState = reserved
            recordPollingEvent("rollover_started", source: "AC Power", interval: 30,
                               extra: ["opportunities": keys, "model": model])
            sendAttempted = true
            let turn = try await cli.startResetWindow(model: model)
            recordPollingEvent("rollover_finished", source: "AC Power", interval: 30,
                               extra: ["turnSucceeded": turn.succeeded, "exitStatus": turn.terminationStatus,
                                       "durationSeconds": Date().timeIntervalSince(executionStartedAt), "resetConfirmed": false,
                                       "opportunities": keys])
        } catch {
            recordPollingEvent(sendAttempted ? "rollover_uncertain" : "rollover_probe_failed", source: "AC Power", interval: 30,
                               extra: ["opportunities": keys, "retrySuppressed": sendAttempted,
                                       "errorCategory": String(describing: type(of: error)),
                                       "durationSeconds": Date().timeIntervalSince(executionStartedAt)])
        }
        guard sendAttempted else { return }
        await refresh()
        if let after = self.snapshot {
            let confirmed = keys.filter { key in
                let window = key.hasPrefix("5H:") ? after.fiveHour : after.weekly
                guard let reset = window?.resetsAt, let old = rollingState.boundaries[key.hasPrefix("5H:") ? "5H" : "WEEK"] else { return false }
                return reset > Date() && reset.timeIntervalSince(old) > 60 && (window?.usedPercent ?? 0) > 0
            }
            recordPollingEvent("rollover_verified", source: "AC Power", interval: 30,
                               extra: ["confirmedOpportunities": confirmed, "opportunities": keys])
        }
    }
    /// Timestamp of the last explicit widget timeline reload. Background polls
    /// reuse it to skip a reload while the widget still shows a fresh reading.
    private var lastWidgetReloadAt: Date?
    private static let widgetReloadInterval: TimeInterval = 15 * 60
    /// Bumped by `resetLocalAppData()` so an in-flight refresh cannot write
    /// freshly fetched data back over a just-cleared local state.
    private var dataGeneration = 0

    init() {
        snapshot = LimitStore.read()
        preferences = LimitPreferencesStore.read()
        lastSuccessfulSyncAt = snapshot?.updatedAt
        lastCLIErrorMessage = snapshot?.errorMessage
        #if DEBUG
        assert(LegacyUsageSnapshotCheck.passes(), "A snapshot saved before usage.updatedAt existed no longer decodes")
        #endif
        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        widgetBridge.start()
        widgetBridge.publish(WidgetPayload(snapshot: snapshot, preferences: preferences))
        configureLoginItem()
        configureSystemNotificationsIfNeeded()
        Task { await automaticRefreshIfDue() }
        // Recheck the power source every 30 seconds, without fetching data on
        // battery until the five-minute interval has elapsed.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.automaticRefreshIfDue()
            }
        }
    }

    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing, !isAuthenticating, !isInstallingCLI else { return }
        isRefreshing = true
        // A background poll keeps the last reading on screen. Only a manual
        // refresh, or the very first poll without data, shows the checking state.
        if userInitiated || snapshot == nil {
            connectionState = .checking
        }
        connectionMessage = nil
        defer { isRefreshing = false }
        let generation = dataGeneration

        do {
            var fresh = try await client.fetch()
            guard generation == dataGeneration else { return }
            if fresh.usage == nil {
                fresh.usage = snapshot?.usage
            }
            normalizeCompactMenuBarMetric(for: fresh)
            let contentChanged = Self.contentChanged(from: snapshot, to: fresh)
            snapshot = fresh
            do {
                try LimitStore.write(fresh)
            } catch {
                LimitLog.store.error("LimitStore.write failed: \(error.localizedDescription)")
            }
            lastSuccessfulSyncAt = fresh.updatedAt
            lastCLIErrorMessage = nil
            lastCLIErrorAt = nil
            publishSnapshot()
            if contentChanged || widgetReloadIsDue() {
                reloadWidgetTimelines()
            }
            await lowLimitNotificationManager.deliverIfNeeded(for: fresh, preferences: preferences)
            connectionState = .ready
        } catch {
            guard generation == dataGeneration else { return }
            handleRefreshFailure(error)
        }
    }

    func authenticate() async {
        guard !isAuthenticating, !isInstallingCLI, !isRefreshing else { return }

        let cli: CodexCLI
        do {
            cli = try CodexCLI.resolve()
        } catch {
            connectionState = .cliNotInstalled
            connectionMessage = nil
            return
        }

        isAuthenticating = true
        connectionState = .authenticating
        connectionMessage = nil

        do {
            let result = try await cli.run(arguments: ["login"])
            guard result.succeeded else {
                throw CodexCLICommandError.loginFailed(result.combinedOutput)
            }

            let authenticationStatus = try await cli.authenticationStatus()
            isAuthenticating = false

            switch authenticationStatus {
            case .loggedIn:
                await refresh()
            case .notLoggedIn:
                connectionState = .authenticationRequired
                connectionMessage = "Codex login did not complete."
            }
        } catch {
            isAuthenticating = false
            connectionState = .authenticationRequired
            connectionMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func installCLI() async {
        guard !isInstallingCLI, !isAuthenticating, !isRefreshing else { return }

        isInstallingCLI = true
        connectionState = .installing
        connectionMessage = nil

        do {
            try await CodexCLIInstaller.install()
            let cli = try CodexCLI.resolve()
            _ = try await cli.version()
            let authenticationStatus = try await cli.authenticationStatus()
            isInstallingCLI = false

            switch authenticationStatus {
            case .loggedIn:
                await refresh()
            case .notLoggedIn:
                await authenticate()
            }
        } catch {
            isInstallingCLI = false
            connectionState = .cliNotInstalled
            connectionMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var isCodexActionBusy: Bool {
        isRefreshing || isAuthenticating || isInstallingCLI
    }

    var connectionStateTitle: String {
        switch connectionState {
        case .checking:
            return "Checking Codex CLI"
        case .ready:
            return "Codex CLI connected"
        case .authenticationRequired:
            return "Codex CLI authentication required"
        case .cliNotInstalled:
            return "Codex CLI is not installed"
        case .installing:
            return "Installing Codex CLI"
        case .authenticating:
            return "Waiting for browser authorization"
        case .failed:
            return "Codex CLI error"
        }
    }

    var connectionStateDetail: String? {
        switch connectionState {
        case .cliNotInstalled:
            let base = "ChatGPT Desktop with Codex does not provide CLI access for this app."
            guard let connectionMessage else { return base }
            return "\(connectionMessage)\nManual install: \(CodexCLIInstaller.manualInstallCommand)"
        case .authenticationRequired:
            let base = "Sign in to Codex CLI with your ChatGPT account."
            guard let connectionMessage else { return base }
            return "\(base)\n\(connectionMessage)"
        case .installing:
            return "Downloading the official installer and checking the user installation."
        case .authenticating:
            return "Complete the sign-in in your browser."
        case .failed:
            return connectionMessage
        case .checking, .ready:
            return nil
        }
    }

    var connectionActionTitle: String? {
        switch connectionState {
        case .authenticationRequired:
            return "Authorize"
        case .cliNotInstalled:
            return "Install Codex CLI"
        default:
            return nil
        }
    }

    var connectionActionIcon: String {
        connectionState == .cliNotInstalled ? "arrow.down.circle" : "person.badge.key"
    }

    var showsConnectionStatus: Bool {
        switch connectionState {
        case .checking, .ready:
            return false
        case .authenticationRequired, .cliNotInstalled, .installing, .authenticating, .failed:
            return true
        }
    }

    private func handleRefreshFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let knownState: CodexConnectionState?

        if let rateLimitError = error as? CodexRateLimitError {
            switch rateLimitError {
            case .codexNotFound:
                knownState = .cliNotInstalled
            case .authenticationRequired:
                knownState = .authenticationRequired
            case .timeout, .missingCodexLimit, .invalidWindow:
                knownState = nil
            }
        } else {
            knownState = nil
        }

        connectionState = knownState ?? .failed
        connectionMessage = knownState == nil ? message : nil
        lastCLIErrorMessage = message
        lastCLIErrorAt = Date()

        if var current = snapshot {
            current.errorMessage = knownState == nil ? message : nil
            snapshot = current
            do {
                try LimitStore.write(current)
            } catch {
                LimitLog.store.error("LimitStore.write failed: \(error.localizedDescription)")
            }
            reloadWidgets()
        }
    }

    @discardableResult
    func updatePreferences(_ update: (inout LimitPreferences) -> Void) -> Bool {
        var next = preferences
        update(&next)
        let scheduleChanged = next.nextFiveHourResetTarget != preferences.nextFiveHourResetTarget
        let rollingChanged = next.keepsResetWindowsRolling != preferences.keepsResetWindowsRolling
        do {
            try LimitPreferencesStore.write(next)
            preferences = next
            if scheduleChanged || rollingChanged {
                recordPollingEvent("rollover_settings_changed", source: lastObservedPowerSource ?? "unknown", interval: 30,
                                   extra: ["enabled": next.keepsResetWindowsRolling,
                                           "scheduleTarget": next.nextFiveHourResetTarget.map { ISO8601DateFormatter().string(from: $0) } ?? "none"])
            }
        } catch {
            LimitLog.store.error("LimitPreferencesStore.write failed: \(error.localizedDescription)")
            recordPollingEvent("preferences_save_failed", source: lastObservedPowerSource ?? "unknown", interval: 30)
            return false
        }
        reloadWidgets()
        return true
    }

    // MARK: - Low limit alerts, per window

    func lowLimitAlertsEnabled(for window: LowLimitAlertWindow) -> Bool {
        preferences.lowLimitAlertsEnabled(for: window)
    }

    /// Turning a window on asks for system authorization first and only then
    /// stores the setting, so the switch never claims alerts that cannot be
    /// delivered. Turning it off is immediate.
    func setLowLimitAlertsEnabled(_ isEnabled: Bool, for window: LowLimitAlertWindow) {
        guard isEnabled else {
            updatePreferences { $0.setLowLimitAlertsEnabled(false, for: window) }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard await lowLimitNotificationManager.requestAuthorization() else { return }
            updatePreferences { $0.setLowLimitAlertsEnabled(true, for: window) }
            if let snapshot {
                await lowLimitNotificationManager.deliverIfNeeded(for: snapshot, preferences: preferences)
            }
        }
    }

    func lowLimitThresholds(for window: LowLimitAlertWindow) -> [Int?] {
        preferences.lowLimitThresholds(for: window)
    }

    func canAddLowLimitThreshold(for window: LowLimitAlertWindow) -> Bool {
        lowLimitThresholds(for: window).count < LimitPreferences.maximumNotificationThresholds
    }

    func canRemoveLowLimitThreshold(for window: LowLimitAlertWindow) -> Bool {
        !lowLimitThresholds(for: window).isEmpty
    }

    func addLowLimitThreshold(for window: LowLimitAlertWindow) {
        updatePreferences { preferences in
            var thresholds = preferences.lowLimitThresholds(for: window)
            guard thresholds.count < LimitPreferences.maximumNotificationThresholds else { return }
            let last = thresholds.reversed().compactMap { $0 }.first ?? 5
            thresholds.append(min(100, last + 5))
            preferences.setLowLimitThresholds(thresholds, for: window)
        }
    }

    func removeLastLowLimitThreshold(for window: LowLimitAlertWindow) {
        updatePreferences { preferences in
            var thresholds = preferences.lowLimitThresholds(for: window)
            guard !thresholds.isEmpty else { return }
            thresholds.removeLast()
            preferences.setLowLimitThresholds(thresholds, for: window)
        }
    }

    /// Writes one threshold field. `index` beyond the current list appends,
    /// and an empty field is stored as nil so the editor can hold blank rows.
    func setLowLimitNotificationThreshold(
        _ value: Int?,
        at index: Int,
        for window: LowLimitAlertWindow
    ) {
        updatePreferences { preferences in
            var thresholds = preferences.lowLimitThresholds(for: window)
            while thresholds.count <= index {
                thresholds.append(nil)
            }
            thresholds[index] = value
            preferences.setLowLimitThresholds(thresholds, for: window)
        }
    }

    func removeEmptyLowLimitThresholds(for window: LowLimitAlertWindow) {
        let compacted = lowLimitThresholds(for: window).compactMap { $0 }
        guard compacted.count != lowLimitThresholds(for: window).count else { return }
        updatePreferences { $0.setLowLimitThresholds(compacted, for: window) }
    }

    // MARK: - Diagnostics

    /// Where the displayed limits come from. The app never reads a cached
    /// third-party service; every successful sync goes through the local CLI.
    var dataSourceDescription: String {
        "Codex CLI (codex app-server --stdio, account/rateLimits/read)"
    }

    /// Formatted time of the last successful sync, or nil before the first one.
    var lastSyncText: String? {
        guard let lastSuccessfulSyncAt else { return nil }
        return formattedDiagnosticsDate(lastSuccessfulSyncAt)
    }

    /// Last CLI/app-server failure in the current app language, with its time.
    var lastErrorText: String? {
        guard let lastCLIErrorMessage, !lastCLIErrorMessage.isEmpty else { return nil }
        guard let lastCLIErrorAt else { return lastCLIErrorMessage }
        return "\(formattedDiagnosticsDate(lastCLIErrorAt)): \(lastCLIErrorMessage)"
    }

    private func formattedDiagnosticsDate(_ date: Date) -> String {
        let locale = preferences.appLanguage.locale
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = locale.identifier.lowercased().hasPrefix("ru") ? "d MMM, HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Local data reset

    /// Removes only this app's local data: stored snapshot, preferences, widget
    /// payload, and notification history. The Codex account, CLI installation,
    /// and CLI authentication are never touched.
    func resetLocalAppData() async {
        dataGeneration += 1

        LimitStore.removeStoredSnapshot()
        LimitPreferencesStore.removeStoredPreferences()
        WidgetPayloadStore.removeStoredPayload()
        await lowLimitNotificationManager.resetHistory()

        snapshot = nil
        preferences = .default
        lastSuccessfulSyncAt = nil
        lastCLIErrorMessage = nil
        lastCLIErrorAt = nil
        connectionMessage = nil
        connectionState = .checking

        reloadWidgets()
    }

    var menuBarTitle: String {
        guard let snapshot, !hidesCurrentMenuBarMetric else { return "Codex --" }

        switch preferences.menuBarMode {
        case .detailed:
            if let creditsText = detailedMenuBarCreditValue {
                return creditsText
            }

            var parts: [String] = []
            if let weekly = snapshot.weekly {
                parts.append(menuBarValue(for: weekly))
            }
            if let fiveHour = snapshot.fiveHour {
                parts.append("FH \(menuBarValue(for: fiveHour))")
            }
            return parts.isEmpty ? "Codex --" : parts.joined(separator: " ")
        case .percentOnly:
            return compactMenuBarValue
        }
    }

    private var detailedMenuBarCreditValue: String? {
        guard let snapshot,
              let creditsText = snapshot.credits?.displayText(maxFractionDigits: 4),
              (snapshot.fiveHour?.usedPercent ?? 0) >= 100 ||
              (snapshot.weekly?.usedPercent ?? 0) >= 100
        else {
            return nil
        }

        return creditsText
    }

    private func menuBarValue(for window: LimitWindowSnapshot) -> String {
        if window.usedPercent >= 100,
           let creditsText = snapshot?.credits?.displayText(maxFractionDigits: 2) {
            return creditsText
        }

        return "\(window.leftPercent)%"
    }

    var compactMenuBarValue: String {
        guard let snapshot, !hidesCurrentMenuBarMetric else { return "—" }

        let window: LimitWindowSnapshot?
        switch preferences.compactMenuBarMetric {
        case .fiveHour:
            window = snapshot.fiveHour ?? snapshot.weekly
        case .weekly:
            window = snapshot.weekly ?? snapshot.fiveHour
        }

        guard let window else { return "0%" }
        return menuBarValue(for: window)
    }

    var compactMenuBarPercent: Int {
        guard let snapshot, !hidesCurrentMenuBarMetric else { return 0 }

        switch preferences.compactMenuBarMetric {
        case .fiveHour:
            return (snapshot.fiveHour ?? snapshot.weekly)?.leftPercent ?? 0
        case .weekly:
            return (snapshot.weekly ?? snapshot.fiveHour)?.leftPercent ?? 0
        }
    }

    var availableCompactMenuBarMetrics: [MenuBarCompactMetric] {
        guard let snapshot else { return [] }
        return availableCompactMenuBarMetrics(for: snapshot)
    }

    private func availableCompactMenuBarMetrics(for snapshot: LimitSnapshot) -> [MenuBarCompactMetric] {
        var metrics: [MenuBarCompactMetric] = []
        if snapshot.fiveHour != nil {
            metrics.append(.fiveHour)
        }
        if snapshot.weekly != nil {
            metrics.append(.weekly)
        }
        return metrics
    }

    private func normalizeCompactMenuBarMetric(for snapshot: LimitSnapshot) {
        let availableMetrics = availableCompactMenuBarMetrics(for: snapshot)
        guard !availableMetrics.contains(preferences.compactMenuBarMetric),
              let fallbackMetric = availableMetrics.first
        else { return }

        preferences.compactMenuBarMetric = fallbackMetric
        do {
            try LimitPreferencesStore.write(preferences)
        } catch {
            LimitLog.store.error("LimitPreferencesStore.write failed: \(error.localizedDescription)")
        }
    }

    private var hidesCurrentMenuBarMetric: Bool {
        switch connectionState {
        case .authenticationRequired, .cliNotInstalled, .installing, .authenticating:
            return true
        case .checking, .ready, .failed:
            return false
        }
    }

    private func configureLoginItem() {
        if #available(macOS 13.0, *) {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: loginItemSetupKey) else { return }

            #if DEBUG
            let isDebugBuild = true
            #else
            let isDebugBuild = false
            #endif

            guard LoginItemRegistrationPolicy.shouldRegister(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                bundleURL: Bundle.main.bundleURL,
                isDebugBuild: isDebugBuild
            ) else { return }

            let service = SMAppService.mainApp
            guard service.status == .notRegistered else {
                defaults.set(true, forKey: loginItemSetupKey)
                return
            }

            // Existing installations have already passed their first launch.
            // Do not register them again when an update leaves SMAppService in
            // a transient `notRegistered` state.
            guard !LimitPreferencesStore.hasStoredPreferences,
                  !LimitStore.hasStoredSnapshot else {
                defaults.set(true, forKey: loginItemSetupKey)
                return
            }

            do {
                try service.register()
            } catch {
                LimitLog.update.error("SMAppService.register failed: \(error.localizedDescription)")
            }
            defaults.set(true, forKey: loginItemSetupKey)
        }
    }

    private func configureSystemNotificationsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: notificationSetupKey) else { return }

        Task { [weak self] in
            guard let self else { return }
            let isAuthorized = await lowLimitNotificationManager.requestAuthorization()
            updatePreferences { preferences in
                for window in LowLimitAlertWindow.allCases {
                    preferences.setLowLimitAlertsEnabled(isAuthorized, for: window)
                }
            }
            UserDefaults.standard.set(true, forKey: notificationSetupKey)
        }
    }

    /// Compares two snapshots without the stamps that every successful poll
    /// refreshes so an unchanged reading does not trigger a widget reload.
    private static func contentChanged(from old: LimitSnapshot?, to new: LimitSnapshot) -> Bool {
        guard var previous = old else { return true }
        previous.updatedAt = new.updatedAt
        var candidate = new
        if previous.usage != nil, candidate.usage != nil {
            // Only a change of the usage freshness reaches the screen; a fresh
            // timestamp on the same numbers does not.
            guard previous.usage?.isStale == candidate.usage?.isStale else { return true }
            previous.usage?.updatedAt = nil
            candidate.usage?.updatedAt = nil
        }
        return previous != candidate
    }

    private func widgetReloadIsDue() -> Bool {
        guard let lastWidgetReloadAt else { return true }
        return Date().timeIntervalSince(lastWidgetReloadAt) >= Self.widgetReloadInterval
    }

    private func publishSnapshot() {
        widgetBridge.publish(WidgetPayload(snapshot: snapshot, preferences: preferences))
    }

    private func reloadWidgetTimelines() {
        lastWidgetReloadAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKindIdentifier)
    }

    private func reloadWidgets() {
        publishSnapshot()
        reloadWidgetTimelines()
    }
}

private actor LowLimitNotificationManager {
    private struct LimitWindowCycle: Codable, Equatable {
        let kind: LowLimitAlertWindow
        let resetAtQuarterHour: Int64
    }

    private struct NotificationDelivery: Codable {
        let cycle: LimitWindowCycle
        let threshold: Int
        let deliveredAt: Date
    }

    private struct DeliveryLedger: Codable {
        var deliveries: [NotificationDelivery] = []
        // Keep the old string keys while users upgrade from 1.2.0. They stop
        // the same alert from being sent twice during the current reset cycle.
        var legacyDeliveryKeys: Set<String> = []
        // Reset cycle (quarter-hour index) in which a limit was last seen
        // depleted, keyed by window kind. A later, different cycle means the
        // limit came back and a restoration alert is due once per cycle.
        var depletedCycles: [String: Int64] = [:]
        var restoredCycles: [String: Int64] = [:]

        private enum CodingKeys: String, CodingKey {
            case deliveries
            case deliveredKeys
            case depletedCycles
            case restoredCycles
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deliveries = try container.decodeIfPresent([NotificationDelivery].self, forKey: .deliveries) ?? []
            legacyDeliveryKeys = try container.decodeIfPresent(Set<String>.self, forKey: .deliveredKeys) ?? []
            depletedCycles = try container.decodeIfPresent([String: Int64].self, forKey: .depletedCycles) ?? [:]
            restoredCycles = try container.decodeIfPresent([String: Int64].self, forKey: .restoredCycles) ?? [:]
        }

        func contains(_ cycle: LimitWindowCycle, threshold: Int, legacyKey: String?) -> Bool {
            deliveries.contains { $0.cycle == cycle && $0.threshold == threshold }
                || legacyKey.map { legacyDeliveryKeys.contains($0) } == true
        }

        mutating func record(_ cycle: LimitWindowCycle, threshold: Int, deliveredAt: Date) {
            deliveries.append(NotificationDelivery(cycle: cycle, threshold: threshold, deliveredAt: deliveredAt))
        }

        func depletedCycle(for kind: LowLimitAlertWindow) -> Int64? {
            depletedCycles[kind.rawValue]
        }

        mutating func recordDepleted(for kind: LowLimitAlertWindow, cycleAtQuarterHour: Int64) {
            depletedCycles[kind.rawValue] = cycleAtQuarterHour
        }

        mutating func clearDepleted(for kind: LowLimitAlertWindow) {
            depletedCycles.removeValue(forKey: kind.rawValue)
        }

        func didRestore(for kind: LowLimitAlertWindow, cycleAtQuarterHour: Int64) -> Bool {
            restoredCycles[kind.rawValue] == cycleAtQuarterHour
        }

        mutating func recordRestored(for kind: LowLimitAlertWindow, cycleAtQuarterHour: Int64) {
            restoredCycles[kind.rawValue] = cycleAtQuarterHour
        }

        mutating func removeExpiredEntries(now: Date) {
            // A weekly cycle can remain active for seven days. Retain completed
            // cycles for 30 days so partial API responses cannot erase history.
            let cutoff = Int64(now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970 / 900)
            deliveries.removeAll { $0.cycle.resetAtQuarterHour < cutoff }
            restoredCycles = restoredCycles.filter { $0.value >= cutoff }
            depletedCycles = depletedCycles.filter { $0.value >= cutoff }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(deliveries, forKey: .deliveries)
            try container.encode(legacyDeliveryKeys, forKey: .deliveredKeys)
            try container.encode(depletedCycles, forKey: .depletedCycles)
            try container.encode(restoredCycles, forKey: .restoredCycles)
        }
    }

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        default:
            return false
        }
    }

    /// Authorization check that never raises the system prompt.
    private func hasNotificationAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    /// Clears this app's notification history: the delivery ledger plus any
    /// notifications the app already posted or scheduled. Both are app-owned:
    /// the ledger is this app's file in Application Support and
    /// `UNUserNotificationCenter.current()` is scoped to this app's bundle.
    func resetHistory() async {
        try? FileManager.default.removeItem(at: ledgerURL())
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func deliverIfNeeded(for snapshot: LimitSnapshot, preferences: LimitPreferences) async {
        let sendsRestorationAlerts = preferences.restorationNotificationsEnabled
        // Each window keeps its own switch, so authorization and delivery are
        // decided per window rather than by one shared flag.
        let alertWindows = LowLimitAlertWindow.allCases.filter { preferences.lowLimitAlertsEnabled(for: $0) }
        guard !alertWindows.isEmpty || sendsRestorationAlerts else { return }

        // Only the low-limit toggle may raise the system prompt. Restoration
        // alerts reuse an authorization the user already granted.
        let isAuthorized = alertWindows.isEmpty
            ? await hasNotificationAuthorization()
            : await requestAuthorization()
        guard isAuthorized else { return }

        let now = Date()
        // Quiet hours suppress low-limit alerts only; a limit that came back is
        // still worth reporting, so restoration alerts are never held back.
        let suppressLowLimitAlerts = preferences.isQuietHoursActive(at: now)

        var ledger = readLedger()
        ledger.removeExpiredEntries(now: now)
        let windows: [(LowLimitAlertWindow, LimitWindowSnapshot)] = [
            snapshot.fiveHour.map { (.fiveHour, $0) },
            snapshot.weekly.map { (.weekly, $0) }
        ].compactMap { $0 }

        for (kind, window) in windows {
            guard let cycle = cycle(for: window, kind: kind) else { continue }
            let isDepleted = window.usedPercent >= 100

            if !isDepleted, let depletedCycle = ledger.depletedCycle(for: kind), depletedCycle != cycle.resetAtQuarterHour {
                if sendsRestorationAlerts, !ledger.didRestore(for: kind, cycleAtQuarterHour: cycle.resetAtQuarterHour) {
                    if await deliverRestorationNotification(
                        for: window,
                        kind: kind,
                        cycleAtQuarterHour: cycle.resetAtQuarterHour,
                        preferences: preferences
                    ) {
                        ledger.recordRestored(for: kind, cycleAtQuarterHour: cycle.resetAtQuarterHour)
                        ledger.clearDepleted(for: kind)
                    }
                } else {
                    ledger.clearDepleted(for: kind)
                }
            }

            if isDepleted {
                ledger.recordDepleted(for: kind, cycleAtQuarterHour: cycle.resetAtQuarterHour)
            }

            guard preferences.lowLimitAlertsEnabled(for: kind), !suppressLowLimitAlerts else { continue }

            // Several thresholds can match if the app first sees an already-low
            // value. Alert only for the nearest one; lower thresholds can still
            // alert later as the remaining percentage continues to fall.
            guard let threshold = preferences.lowLimitThresholds(for: kind)
                .compactMap({ $0 })
                .filter({ window.leftPercent <= $0 })
                .min()
            else { continue }

            let legacyKey = legacyDeliveryKey(for: window, threshold: threshold)
            guard !ledger.contains(cycle, threshold: threshold, legacyKey: legacyKey) else { continue }

            let isRussian = preferences.appLanguage.locale.identifier.lowercased().hasPrefix("ru")
            let windowName = Self.notificationWindowName(for: kind, isRussian: isRussian)
            let content = UNMutableNotificationContent()
            content.title = isRussian ? "Лимит Codex заканчивается" : "Codex limit is running low"
            content.body = isRussian
                ? "\(windowName): осталось \(window.leftPercent)% (порог уведомления \(threshold)%)."
                : "\(windowName): \(window.leftPercent)% remaining (alert threshold \(threshold)%)."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codex-limit.\(kind.rawValue).\(cycle.resetAtQuarterHour).\(threshold)",
                content: content,
                trigger: nil
            )

            do {
                try await center.add(request)
                ledger.record(cycle, threshold: threshold, deliveredAt: Date())
            } catch {
                continue
            }
        }
        writeLedger(ledger)
    }

    /// Limit window name for notification text, which is built outside SwiftUI
    /// and therefore cannot use the app-language string lookup.
    private static func notificationWindowName(for kind: LowLimitAlertWindow, isRussian: Bool) -> String {
        switch kind {
        case .fiveHour:
            return isRussian ? "5 часов" : "5 hours"
        case .weekly:
            return isRussian ? "Неделя" : "Week"
        }
    }

    /// Sends the once-per-cycle "limit is available again" alert in the app language.
    private func deliverRestorationNotification(
        for window: LimitWindowSnapshot,
        kind: LowLimitAlertWindow,
        cycleAtQuarterHour: Int64,
        preferences: LimitPreferences
    ) async -> Bool {
        let isRussian = preferences.appLanguage.locale.identifier.lowercased().hasPrefix("ru")
        let windowName = Self.notificationWindowName(for: kind, isRussian: isRussian)

        let content = UNMutableNotificationContent()
        content.title = isRussian ? "Лимит Codex восстановлен" : "Codex limit restored"
        content.body = isRussian
            ? "\(windowName): лимит сброшен, снова доступно \(window.leftPercent)%."
            : "\(windowName): the limit reset and \(window.leftPercent)% is available again."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "codex-limit.restored.\(kind.rawValue).\(cycleAtQuarterHour)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func cycle(for window: LimitWindowSnapshot, kind: LowLimitAlertWindow) -> LimitWindowCycle? {
        guard let resetsAt = window.resetsAt else { return nil }
        // The API can shift a reset timestamp by seconds between refreshes.
        // Rounding to 15-minute buckets keeps one real reset cycle stable.
        let resetAtQuarterHour = Int64((resetsAt.timeIntervalSince1970 / 900).rounded())
        return LimitWindowCycle(kind: kind, resetAtQuarterHour: resetAtQuarterHour)
    }

    private func legacyDeliveryKey(for window: LimitWindowSnapshot, threshold: Int) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        let resetHour = Int(resetsAt.timeIntervalSince1970 / 3_600)
        return "\(window.windowDurationMins ?? 0)-\(resetHour)|\(threshold)"
    }

    private func readLedger() -> DeliveryLedger {
        let url = ledgerURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DeliveryLedger()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder.codexLimitDecoder.decode(DeliveryLedger.self, from: data)
        } catch {
            LimitLog.store.error("Notification ledger read failed: \(error.localizedDescription)")
            return DeliveryLedger()
        }
    }

    private func writeLedger(_ ledger: DeliveryLedger) {
        let data: Data
        do {
            data = try JSONEncoder.codexLimitEncoder.encode(ledger)
        } catch {
            LimitLog.store.error("Notification ledger encode failed: \(error.localizedDescription)")
            return
        }
        let url = ledgerURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            LimitLog.store.error("Notification ledger write failed: \(error.localizedDescription)")
        }
    }

    private func ledgerURL() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("CodexLimitWidgetCustom", isDirectory: true)
            .appendingPathComponent("low-limit-notification-ledger.json")
    }
}

private final class LoopbackWidgetBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.calaborhoc.codexlimitwidgetcustom.loopback")
    private var listener: NWListener?
    private var responseData = Data()

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 38348)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    func publish(_ payload: WidgetPayload) {
        let data = (try? JSONEncoder.codexLimitEncoder.encode(payload)) ?? Data()
        queue.sync { responseData = data }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let isPayloadRequest = request.hasPrefix("GET /v1/widget-payload ")
            let body = isPayloadRequest ? self.responseData : Data()
            let status = isPayloadRequest ? "200 OK" : "404 Not Found"
            let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
