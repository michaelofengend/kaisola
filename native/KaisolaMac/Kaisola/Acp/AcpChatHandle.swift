import Foundation

/// A live ACP chat in the app's chat list. Holds the conversation view-model;
/// identity is a synthetic per-open id (ACP sessions are app-scoped, not
/// broker-durable, so they need no broker terminal id).
struct AcpChatHandle: Identifiable {
    let id: String
    let agentID: String
    let conversation: AcpConversation
}
