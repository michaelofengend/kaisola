import Foundation

extension NativeSessionStore {
    /// Move a project tab to an absolute `toIndex` in the persisted order — the
    /// destination of a pointer drag-reorder.
    ///
    /// Implemented by looping the existing public `moveProject(id:delta:)`
    /// (which swaps one adjacent slot per call) rather than a direct
    /// remove-and-insert, because the store's `read()` / `write()` helpers are
    /// `private` and unreachable from an extension in a separate file. Walking
    /// the tab one slot at a time in a single direction reproduces exactly a
    /// remove-at-source + insert-at-destination rotation: `n` adjacent swaps
    /// shift the `n` intervening tabs over by one and land the dragged tab on
    /// `toIndex`, which is what the drag gesture wants.
    ///
    /// `toIndex` is clamped into range. A no-op when `id` is absent or already
    /// at the destination.
    func moveProject(id: String, toIndex: Int) {
        let order = projects()
        guard let from = order.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(toIndex, order.count - 1))
        guard clamped != from else { return }
        let delta = clamped > from ? 1 : -1
        for _ in 0..<abs(clamped - from) {
            moveProject(id: id, delta: delta)
        }
    }
}
