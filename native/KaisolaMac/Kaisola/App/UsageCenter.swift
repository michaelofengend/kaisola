import Combine
import Foundation

/// Session-lifetime token-usage aggregator across every ACP chat in the app.
///
/// Each `AcpConversation` publishes a live per-chat context window (`AcpUsage`
/// used/max) that the chat header shows on its own. Electron additionally shows
/// whole-session usage gauges; the native app had no equivalent. `UsageCenter`
/// fills that gap: it fans every chat's usage updates into one place so the
/// Settings ▸ Usage tab and the footer cost chip can show session totals and
/// context pressure. State is in-memory and lasts for the app session only
/// (nothing is persisted — this mirrors Electron's live gauges, not history).
@MainActor
final class UsageCenter: ObservableObject {
    /// The canonical instance the app UI observes. Tests may construct their own
    /// isolated instance via `init()` to avoid clobbering shared state.
    static let shared = UsageCenter()

    /// One chat's usage rollup. `latest*` is the most recent context-window
    /// reading (what the gauge shows); `peakUsed` is the high-water mark of used
    /// tokens seen this session (context can shrink after a compaction, so the
    /// latest reading undercounts how much the chat has actually pushed through).
    struct ChatUsage: Identifiable, Equatable {
        let id: String
        var title: String
        var agentID: String
        var latestUsed: Int
        var latestMax: Int
        var peakUsed: Int
        var turns: Int
    }

    @Published private(set) var byChat: [String: ChatUsage] = [:]

    init() {}

    /// Every tracked chat, heaviest first (peak used tokens, descending). The
    /// title/id tiebreak keeps the order stable when peaks match.
    var all: [ChatUsage] {
        byChat.values.sorted { lhs, rhs in
            if lhs.peakUsed != rhs.peakUsed { return lhs.peakUsed > rhs.peakUsed }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    /// Fold one context-window reading into a chat's rollup, creating the entry
    /// on first sight. Refreshes the latest reading and title/agent (they can
    /// change if the chat is renamed or the model switches) and advances the
    /// peak. `turns` is preserved across records.
    func record(chatID: String, title: String, agentID: String, usage used: Int, max: Int) {
        if var existing = byChat[chatID] {
            existing.title = title
            existing.agentID = agentID
            existing.latestUsed = used
            existing.latestMax = max
            existing.peakUsed = Swift.max(existing.peakUsed, used)
            byChat[chatID] = existing
        } else {
            byChat[chatID] = ChatUsage(
                id: chatID,
                title: title,
                agentID: agentID,
                latestUsed: used,
                latestMax: max,
                peakUsed: used,
                turns: 0
            )
        }
    }

    /// Count one completed turn for a chat already being tracked. A no-op for an
    /// unknown chat: a chat that never emitted a usage reading has nothing to
    /// show, so it is deliberately not conjured into existence here.
    func recordTurn(chatID: String) {
        guard var existing = byChat[chatID] else { return }
        existing.turns += 1
        byChat[chatID] = existing
    }

    /// Forget a chat's usage (e.g. when it is closed). Safe for unknown ids.
    func remove(chatID: String) {
        byChat.removeValue(forKey: chatID)
    }

    /// Clear all tracked usage (the Usage tab's Reset button).
    func reset() {
        byChat.removeAll()
    }

    // MARK: - Aggregates

    /// Sum of every chat's peak used tokens — the session's total token weight.
    var totalPeakTokens: Int {
        byChat.values.reduce(0) { $0 + $1.peakUsed }
    }

    /// Highest current context fill across all chats, in `0...1` (0 when there
    /// are no chats, or none has a positive max). Uses the latest reading so it
    /// reflects live pressure, and guards divide-by-zero on an absent max.
    var contextPressure: Double {
        byChat.values.reduce(0.0) { current, usage in
            guard usage.latestMax > 0 else { return current }
            return Swift.max(current, Double(usage.latestUsed) / Double(usage.latestMax))
        }
    }
}
