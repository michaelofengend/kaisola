import Foundation

/// Bounded, mode-0600 transcript persistence for native ACP cards. Provider
/// `session/resume` restores the agent's internal context; this store restores
/// what the user can see immediately, without waiting for an adapter replay.
actor AcpTranscriptStore {
    struct Entry: Codable, Equatable, Sendable {
        var rows: [AcpTranscriptRow]
        var updatedAt: Int64
    }

    private struct Payload: Codable {
        var entries: [String: Entry]
    }

    static let maximumChatCount = 40
    static let maximumRowsPerChat = 600
    static let live = AcpTranscriptStore(fileURL: NativePreviewPaths.agentChatTranscriptStore)

    private let fileURL: URL
    private var pending: [String: Entry] = [:]
    private var flushTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func rows(for chatID: String) -> [AcpTranscriptRow] {
        if let pending = pending[chatID] { return pending.rows }
        return read()?.entries[chatID]?.rows ?? []
    }

    /// Coalesce streaming chunks into one disk write. The visible model remains
    /// live in memory; the durable tail trails it by at most 350 milliseconds.
    func scheduleSave(_ rows: [AcpTranscriptRow], for chatID: String, now: Int64? = nil) {
        guard !chatID.isEmpty else { return }
        pending[chatID] = Entry(
            rows: Array(rows.suffix(Self.maximumRowsPerChat)),
            updatedAt: now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        )
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func remove(chatID: String) {
        pending.removeValue(forKey: chatID)
        var payload = read() ?? Payload(entries: [:])
        payload.entries.removeValue(forKey: chatID)
        write(payload)
    }

    func flush() {
        guard !pending.isEmpty else { return }
        var payload = read() ?? Payload(entries: [:])
        for (id, entry) in pending { payload.entries[id] = entry }
        pending.removeAll()
        if payload.entries.count > Self.maximumChatCount {
            let keep = payload.entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(Self.maximumChatCount)
                .map(\.key)
            payload.entries = payload.entries.filter { Set(keep).contains($0.key) }
        }
        write(payload)
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            let temporary = directory.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)"
            )
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            // Persistence is best-effort; a write failure must never stop a chat.
        }
    }
}
