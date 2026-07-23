import AppKit
import Foundation

/// The cross-project needs-you inbox: one place where background events
/// (permission asks, finished agent turns, responded terminal agents) land when
/// their surface isn't focused. Drives the dock badge and the bell popover.
@MainActor
final class AttentionCenter: ObservableObject {
    static let shared = AttentionCenter()

    enum Kind: Equatable {
        case permission
        case turnCompleted
        case sessionResponded
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let kind: Kind
        /// The chat id or terminal session id to jump to.
        let targetID: String
        let title: String
        let detail: String
        let at: Date
    }

    @Published private(set) var entries: [Entry] = []

    var count: Int { entries.count }

    func notify(kind: Kind, targetID: String, title: String, detail: String) {
        // One live entry per target+kind; a newer event replaces the older.
        entries.removeAll { $0.targetID == targetID && $0.kind == kind }
        entries.append(Entry(
            id: "\(targetID)-\(kind)-\(Int(Date().timeIntervalSince1970 * 1000))",
            kind: kind,
            targetID: targetID,
            title: title,
            detail: detail,
            at: Date()
        ))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        updateBadge()
        NotificationBridge.shared.post(kind: kind, title: title, detail: detail, targetID: targetID)
    }

    /// Clear every entry pointing at a target (called when the user visits it).
    func clear(targetID: String) {
        guard entries.contains(where: { $0.targetID == targetID }) else { return }
        entries.removeAll { $0.targetID == targetID }
        updateBadge()
    }

    func clearAll() {
        entries.removeAll()
        updateBadge()
    }

    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = entries.isEmpty ? nil : "\(entries.count)"
    }
}
