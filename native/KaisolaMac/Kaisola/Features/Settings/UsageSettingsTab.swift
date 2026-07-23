import SwiftUI

/// Settings ▸ Usage: session-lifetime token usage across every ACP chat, the
/// native counterpart to Electron's session usage gauges. Per-chat context
/// gauges plus session totals, sourced from `UsageCenter.shared`.
struct UsageSettingsTab: View {
    @ObservedObject private var usage = UsageCenter.shared

    var body: some View {
        Form {
            if usage.byChat.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No usage yet",
                        systemImage: "gauge.with.dots.needle.bottom.50percent",
                        description: Text("Token usage appears here once an agent chat reports a context window.")
                    )
                }
            } else {
                Section("Chats") {
                    ForEach(usage.all) { chat in
                        ChatUsageRow(chat: chat)
                    }
                }
                totals
                Section {
                    Button("Reset usage", role: .destructive) { usage.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }

    private var totals: some View {
        Section("Session totals") {
            LabeledContent("Total peak tokens", value: Self.tokens(usage.totalPeakTokens))
            LabeledContent("Active chats", value: "\(usage.byChat.count)")
            LabeledContent("Context pressure") {
                let pressure = usage.contextPressure
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Int((pressure * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                    ProgressView(value: pressure)
                        .frame(width: 160)
                        .tint(pressure >= 0.85 ? .orange : .accentColor)
                }
            }
        }
    }

    /// Compact token count: raw below 1k, otherwise "Nk" (parity with the chat
    /// header's `used/1000)k` formatting).
    static func tokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : "\(n / 1000)k"
    }
}

/// One chat's row: title + agent, a context-window gauge, and peak/turn meta.
private struct ChatUsageRow: View {
    let chat: UsageCenter.ChatUsage

    private var agentName: String {
        AgentRegistry.profile(id: chat.agentID)?.name
            ?? (chat.agentID.isEmpty ? "Agent" : chat.agentID)
    }

    private var fraction: Double {
        chat.latestMax > 0 ? Double(chat.latestUsed) / Double(chat.latestMax) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(agentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(fraction >= 0.85 ? .orange : .accentColor)
            HStack {
                Text("\(UsageSettingsTab.tokens(chat.latestUsed)) / \(UsageSettingsTab.tokens(chat.latestMax))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("peak \(UsageSettingsTab.tokens(chat.peakUsed)) · \(chat.turns) turn\(chat.turns == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
