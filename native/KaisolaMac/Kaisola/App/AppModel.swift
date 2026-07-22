import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case looking
        case connecting
        case connected(version: String, pid: Int32, serverEnforcedObserver: Bool)
        case unavailable(String)

        var title: String {
            switch self {
            case .looking: "Looking for broker"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .unavailable: "Offline"
            }
        }

        var detail: String? {
            switch self {
            case let .connected(version, pid, serverEnforced):
                "Broker \(version) · PID \(pid) · \(serverEnforced ? "server-enforced observer" : "local observer policy")"
            case let .unavailable(message): message
            default: nil
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var connectionState: ConnectionState = .looking
    @Published private(set) var sessions: [BrokerTerminalRecord] = []
    @Published var selectedSessionID: String?
    @Published private(set) var terminalDocument = TerminalDocument.empty

    private let locator: BrokerInfoLocating
    private let client: ObserveOnlyBrokerClient
    private var selectedSession: BrokerTerminalRecord?
    private let observerOwnerID = "native-preview"

    init(
        locator: BrokerInfoLocating = BrokerInfoLocator.live(),
        client: ObserveOnlyBrokerClient = ObserveOnlyBrokerClient()
    ) {
        self.locator = locator
        self.client = client
    }

    var projects: [(name: String, sessions: [BrokerTerminalRecord])] {
        Dictionary(grouping: sessions, by: \.projectID)
            .map { (name: $0.key, sessions: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reload() async {
        await client.disconnect()
        connectionState = .looking
        sessions = []
        selectedSession = nil
        selectedSessionID = nil
        terminalDocument = .empty

        do {
            let info = try locator.locate()
            connectionState = .connecting
            await client.setEventHandler { [weak self] event in
                Task { @MainActor in self?.consume(event) }
            }
            await client.setDisconnectHandler { [weak self] error in
                Task { @MainActor in self?.connectionLost(error) }
            }
            let hello = try await client.connect(to: info)
            let status = try await client.inventory()
            sessions = status.terminals
            connectionState = .connected(
                version: hello.version,
                pid: hello.pid,
                serverEnforcedObserver: hello.serverEnforcedObserver
            )
            if let first = sessions.first {
                selectedSessionID = first.id
                await select(first.id)
            }
        } catch {
            connectionState = .unavailable(error.kaisolaSafeDescription)
        }
    }

    func select(_ id: String?) async {
        guard let id, let next = sessions.first(where: { $0.id == id }) else {
            if let current = selectedSession {
                try? await client.unsubscribe(from: current, ownerID: observerOwnerID)
            }
            selectedSession = nil
            selectedSessionID = nil
            terminalDocument = .empty
            return
        }
        if let current = selectedSession, current.id != next.id {
            try? await client.unsubscribe(from: current, ownerID: observerOwnerID)
        }
        selectedSession = next
        selectedSessionID = next.id
        do {
            let result = try await client.subscribe(
                to: next,
                ownerID: observerOwnerID,
                cursor: terminalDocument.sessionID == next.id ? terminalDocument.cursor : nil
            )
            terminalDocument = terminalDocument.applying(result, sessionID: next.id)
        } catch {
            terminalDocument = .failure(sessionID: next.id, message: error.kaisolaSafeDescription)
        }
    }

    func disconnect() async {
        if let selectedSession {
            try? await client.unsubscribe(from: selectedSession, ownerID: observerOwnerID)
        }
        await client.disconnect()
    }

    private func consume(_ event: BrokerEvent) {
        guard event.ownerID == observerOwnerID,
              event.projectID == selectedSession?.projectID,
              event.terminalID == selectedSession?.id else { return }

        switch event.kind {
        case let .output(epoch, startOffset, endOffset, data):
            guard terminalDocument.append(
                epoch: epoch,
                startOffset: startOffset,
                endOffset: endOffset,
                data: data
            ) else {
                Task { await select(selectedSessionID) }
                return
            }
        case .snapshotRequired:
            Task { await select(selectedSessionID) }
        case .exit:
            terminalDocument.exited = true
        case .activity:
            break
        }
    }

    private func connectionLost(_ error: any Error) {
        guard connectionState.isConnected else { return }
        connectionState = .unavailable(error.kaisolaSafeDescription)
    }
}

private extension Error {
    var kaisolaSafeDescription: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The terminal observer could not connect. The running broker and its sessions were left untouched."
    }
}
