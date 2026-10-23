import WidgetKit
import SwiftUI

private final class TimelineCompletionBox<Value>: @unchecked Sendable {
    let completion: (Value) -> Void

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }
}

struct CodexLimitEntry: TimelineEntry {
    let date: Date
    let snapshot: LimitSnapshot?
    let preferences: LimitPreferences
}

struct CodexLimitProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexLimitEntry {
        CodexLimitEntry(date: Date(), snapshot: .placeholder, preferences: .default)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexLimitEntry) -> Void) {
        let completionBox = TimelineCompletionBox(completion)
        Task {
            let payload = await loadPayload() ?? WidgetPayload(snapshot: .placeholder, preferences: .default)
            completionBox.completion(CodexLimitEntry(date: Date(), snapshot: payload.snapshot, preferences: payload.preferences))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexLimitEntry>) -> Void) {
        let completionBox = TimelineCompletionBox(completion)
        Task {
            let payload = await loadPayload() ?? WidgetPayloadStore.read()
            let snapshot = payload?.snapshot
            let preferences = payload?.preferences ?? .default
            let now = Date()
            // Advancing the display age never reads the CLI or claims a new sync.
            // Keep aging the saved reading even when the app stops running.
            let entries = LimitSyncTimeText.timelineDates(syncedAt: snapshot?.updatedAt, now: now).map { date in
                return CodexLimitEntry(date: date, snapshot: snapshot, preferences: preferences)
            }
            LimitLog.widget.info("Timeline generated: \(entries.count) age transitions")
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(15 * 60)
            completionBox.completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    private func loadPayload() async -> WidgetPayload? {
        if let payload = await WidgetBridgeClient.fetch() {
            WidgetPayloadStore.write(payload)
            return payload
        }
        return nil
    }
}
