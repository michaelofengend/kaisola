import SwiftUI

/// Settings ▸ Models & keys: the direct-API credentials (Anthropic, OpenAI)
/// stored in the macOS Keychain and injected into agent terminals/chats.
///
/// Stored values are never shown. Each row reports only "set" or "not set";
/// typing a new value and pressing Save overwrites the stored key, and Clear
/// deletes it. Electron parity: Settings ▸ Models & keys, where the renderer can
/// set / probe / clear a key but never read it back.
struct ApiKeysSettingsTab: View {
    private let store: ApiKeyStore

    init(store: ApiKeyStore = ApiKeyStore()) {
        self.store = store
    }

    var body: some View {
        Form {
            Section("Direct-API keys") {
                ForEach(ApiKeyStore.Key.allCases, id: \.self) { key in
                    ApiKeyRow(store: store, key: key)
                }
                Text("Kept in your macOS Keychain (this device only) and injected as environment variables into agent terminals and chats. Only needed when an agent calls the provider's API directly — CLI sign-ins don't use them. Stored keys are never displayed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }
}

/// One provider row: a masked field that starts empty (the stored value is never
/// loaded into it), a set/not-set caption, Save, and Clear.
private struct ApiKeyRow: View {
    let store: ApiKeyStore
    let key: ApiKeyStore.Key

    @State private var draft = ""
    @State private var isSet = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(
                    isSet ? "Saved — enter a new key to replace" : "Not set",
                    text: $draft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                Button("Save", action: save)
                    .disabled(trimmedDraft.isEmpty)
                if isSet {
                    Button("Clear", role: .destructive, action: clear)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: isSet ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isSet ? Color.green : Color.secondary)
                Text(isSet ? "\(key.rawValue) is set" : "\(key.rawValue) is not set")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        // The row label; the field/status stack sits in the value column.
        .modifier(RowLabel(title: key.title))
        .onAppear(perform: refresh)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh() {
        isSet = store.read(key) != nil
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        errorText = nil
        do {
            try store.write(key, value: draft)
            draft = ""
            refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clear() {
        errorText = nil
        store.delete(key)
        draft = ""
        refresh()
    }
}

/// Puts the provider name in the Form's leading label column, wrapping the row
/// content in `LabeledContent` so it aligns with the rest of the settings form.
private struct RowLabel: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        LabeledContent {
            content
        } label: {
            Text(title)
        }
    }
}
