import AppKit
import Foundation

/// Session pinning: favorites the user floats to the top of their project
/// group (Electron parity). State lives in a standalone `SessionPinStore`.
///
/// The store is created per call (a cheap file read/write) rather than held as
/// extension state — a Swift extension can't add stored properties, so there's
/// no place to cache a single store instance here.
extension AppModel {
    /// Toggle a session's pinned state, then republish so the sidebar reorders.
    func togglePin(_ terminalID: String) {
        let store = SessionPinStore()
        store.setPinned(terminalID, !store.isPinned(terminalID))
        objectWillChange.send()
    }

    /// Whether a session is pinned to the top of its project group.
    func isPinned(_ terminalID: String) -> Bool {
        SessionPinStore().isPinned(terminalID)
    }

    /// Order sessions for display: pinned rows first, then by title, stable
    /// within each group by original position.
    func pinnedSort(_ sessions: [BrokerTerminalRecord]) -> [BrokerTerminalRecord] {
        AppModel.pinnedOrder(sessions, pinned: SessionPinStore().pins())
    }

    /// Pure ordering behind `pinnedSort` with pin membership supplied
    /// explicitly, so the ordering can be tested without touching the persisted
    /// store. Pinned rows sort ahead of unpinned; within each group rows sort by
    /// title, and equal titles keep their original relative order (stable).
    nonisolated static func pinnedOrder(
        _ sessions: [BrokerTerminalRecord],
        pinned: Set<String>
    ) -> [BrokerTerminalRecord] {
        sessions.enumerated().sorted { lhs, rhs in
            let lhsPinned = pinned.contains(lhs.element.id)
            let rhsPinned = pinned.contains(rhs.element.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.element.title != rhs.element.title {
                return lhs.element.title < rhs.element.title
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
