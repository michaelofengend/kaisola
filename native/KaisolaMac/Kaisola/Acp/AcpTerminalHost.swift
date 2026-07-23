import Foundation

/// Executes agent-requested terminals (`terminal/create` … `terminal/release`)
/// as child processes of the app, mirroring the Electron ACP terminal host.
/// Output is buffered with a bounded tail (oldest bytes dropped once past the
/// byte limit, `truncated` set), and exit status resolves any `wait_for_exit`
/// callers. Terminals are app-scoped like the chats that spawn them.
actor AcpTerminalHost {
    struct ExitStatus: Equatable, Sendable {
        let exitCode: Int32?
        let signal: String?
    }

    struct Snapshot: Equatable, Sendable {
        let output: String
        let truncated: Bool
        let exitStatus: ExitStatus?
    }

    static let defaultOutputByteLimit = 1_048_576
    private static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGKILL: "SIGKILL",
        SIGTERM: "SIGTERM", SIGPIPE: "SIGPIPE", SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT",
    ]

    private final class Entry {
        let process: Process
        var buffer = Data()
        var truncated = false
        var byteLimit: Int
        var exitStatus: ExitStatus?
        var released = false
        var waiters: [CheckedContinuation<ExitStatus, Never>] = []

        init(process: Process, byteLimit: Int) {
            self.process = process
            self.byteLimit = byteLimit
        }
    }

    private var entries: [String: Entry] = [:]
    private var counter = 0

    /// Spawn a command. `env` pairs overlay the app environment; a relative or
    /// missing cwd is the caller's responsibility (the client confines it to the
    /// workspace before calling).
    func create(
        command: String,
        args: [String],
        env: [String: String],
        cwd: String,
        outputByteLimit: Int?
    ) throws -> String {
        counter += 1
        let id = "acpterm-\(counter)-\(UUID().uuidString.prefix(6))"
        let process = Process()
        // Run through the login shell so agent commands resolve PATH the same
        // way the user's own terminal would.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let joined = ([command] + args).map { Self.shellQuote($0) }.joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", joined]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let entry = Entry(process: process, byteLimit: max(1, outputByteLimit ?? Self.defaultOutputByteLimit))
        entries[id] = entry

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.append(id: id, data: data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status: ExitStatus = finished.terminationReason == .uncaughtSignal
                ? ExitStatus(exitCode: nil, signal: Self.signalNames[finished.terminationStatus] ?? "SIG\(finished.terminationStatus)")
                : ExitStatus(exitCode: finished.terminationStatus, signal: nil)
            Task { await self?.finish(id: id, status: status) }
        }

        do {
            try process.run()
        } catch {
            entries[id] = nil
            throw error
        }
        return id
    }

    func output(_ id: String) -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        return Snapshot(
            output: String(decoding: entry.buffer, as: UTF8.self),
            truncated: entry.truncated,
            exitStatus: entry.exitStatus
        )
    }

    func waitForExit(_ id: String) async -> ExitStatus? {
        guard let entry = entries[id] else { return nil }
        if let status = entry.exitStatus { return status }
        return await withCheckedContinuation { continuation in
            entry.waiters.append(continuation)
        }
    }

    /// SIGTERM now, SIGKILL if the process lingers.
    func kill(_ id: String) {
        guard let entry = entries[id], entry.exitStatus == nil, entry.process.isRunning else { return }
        let pid = entry.process.processIdentifier
        entry.process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { await self?.forceKillIfRunning(id: id, pid: pid) }
        }
    }

    /// Invalidate the id; a still-running process is killed first.
    func release(_ id: String) {
        guard let entry = entries[id] else { return }
        entry.released = true
        if entry.exitStatus == nil, entry.process.isRunning {
            kill(id)
        } else {
            entries[id] = nil
        }
    }

    func releaseAll() {
        for id in Array(entries.keys) { release(id) }
    }

    // MARK: - Internal

    private func append(id: String, data: Data) {
        guard let entry = entries[id] else { return }
        entry.buffer.append(data)
        if entry.buffer.count > entry.byteLimit {
            // Keep the tail on a UTF-8 boundary so decoding stays clean.
            var dropCount = entry.buffer.count - entry.byteLimit
            while dropCount < entry.buffer.count,
                  entry.buffer[entry.buffer.startIndex + dropCount] & 0xC0 == 0x80 {
                dropCount += 1
            }
            entry.buffer.removeFirst(dropCount)
            entry.truncated = true
        }
    }

    private func finish(id: String, status: ExitStatus) {
        guard let entry = entries[id] else { return }
        entry.exitStatus = status
        for waiter in entry.waiters { waiter.resume(returning: status) }
        entry.waiters.removeAll()
        if entry.released { entries[id] = nil }
    }

    private func forceKillIfRunning(id: String, pid: Int32) {
        guard let entry = entries[id], entry.exitStatus == nil else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
