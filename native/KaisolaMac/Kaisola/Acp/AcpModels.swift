import Foundation
import KaisolaCore

/// The ACP wire protocol version this client speaks (electron/ipc/acp.cjs).
enum AcpWire {
    static let protocolVersion = 1
}

/// A streamed conversation turn item, mirroring the ACP `session/update`
/// variants the Electron renderer consumes (agent_message_chunk,
/// agent_thought_chunk, tool_call, plan, …).
enum AcpTurnItem: Equatable, Sendable, Identifiable {
    case message(id: String, text: String)
    case thought(id: String, text: String)
    case toolCall(AcpToolCall)
    case plan(entries: [AcpPlanEntry])

    var id: String {
        switch self {
        case let .message(id, _): "msg-\(id)"
        case let .thought(id, _): "thought-\(id)"
        case let .toolCall(call): "tool-\(call.id)"
        case .plan: "plan"
        }
    }
}

struct AcpToolCall: Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var kind: String
    var status: Status

    enum Status: String, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }
}

struct AcpPlanEntry: Equatable, Sendable, Identifiable {
    let id: String
    let content: String
    let priority: String
    var status: String
}

/// A permission the agent is asking the user to grant mid-turn.
struct AcpPermissionRequest: Equatable, Sendable, Identifiable {
    let id: Int
    let sessionID: String
    let title: String
    let options: [Option]

    struct Option: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let kind: String
    }
}

/// Live context-window usage from `usage_update`.
struct AcpUsage: Equatable, Sendable {
    let used: Int
    let max: Int
}

/// The result of `session/new`.
struct AcpSessionInfo: Equatable, Sendable {
    let sessionID: String
    let models: [Model]
    let currentModelID: String?

    struct Model: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }
}

/// Capabilities the agent advertised at `initialize`.
struct AcpAgentCapabilities: Equatable, Sendable {
    var loadSession = false
    var promptQueueing = false
    var mcpHTTP = false
    var mcpSSE = false
    var promptImage = false
}

enum AcpClientError: Error, Equatable, LocalizedError {
    case notRunning
    case adapterExited(code: Int32)
    case spawnFailed(String)
    case malformedResponse
    case requestFailed(String)
    case frameTooLarge

    var errorDescription: String? {
        switch self {
        case .notRunning: "The agent is not running."
        case let .adapterExited(code): "The agent process exited (code \(code))."
        case let .spawnFailed(message): "Could not start the agent: \(message)"
        case .malformedResponse: "The agent sent a malformed message."
        case let .requestFailed(message): message
        case .frameTooLarge: "The agent sent an oversized message."
        }
    }
}
