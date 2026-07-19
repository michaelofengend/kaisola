import SwiftUI

/// The pairing sheet: scan (or paste) the code from your Mac's Settings →
/// Companion, confirm the four words on both screens, done. Driven entirely by
/// the coordinator's pairing phase.
struct PairingFlowView: View {
    @EnvironmentObject private var coordinator: CompanionConnectionCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showPaste = false
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                content
                    .padding(.horizontal, 22)
            }
            .navigationTitle("Pair your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { coordinator.cancelPairing(); dismiss() }
                }
            }
            .onChange(of: isPaired) { _, paired in
                if paired { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() } }
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var isPaired: Bool { if case .paired = coordinator.pairingPhase { return true }; return false }
    private var isBusy: Bool {
        switch coordinator.pairingPhase {
        case .preparing, .connecting, .confirm: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.pairingPhase {
        case .idle, .failed:
            scanStep
        case .preparing, .connecting:
            progressStep(coordinator.pairingPhase == .preparing ? "Unlocking your device…" : "Connecting to your Mac…")
        case let .confirm(sas):
            confirmStep(sas)
        case .paired:
            pairedStep
        }
    }

    // MARK: Steps

    private var scanStep: some View {
        VStack(spacing: 18) {
            if QRScannerView.isSupported && !showPaste {
                QRScannerView { code in scan(code) }
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(KaisolaTheme.accent.opacity(0.5), lineWidth: 1.5) }
                Text("On your Mac, open Settings → Companion, turn it on, and tap “Pair a device.” Point your phone at the code.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Enter code manually") { showPaste = true }
                    .font(.subheadline.weight(.medium)).foregroundStyle(KaisolaTheme.accent)
            } else {
                pasteStep
            }
            if case let .failed(message) = coordinator.pairingPhase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(KaisolaTheme.failed)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste the pairing code")
                .font(.headline)
            Text("On your Mac, the Companion pairing sheet can copy its code. Paste it here.")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $pasted)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 150)
                .padding(8)
                .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
            Button {
                scan(pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text("Pair").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(KaisolaTheme.darkFrame)
                    .background(pasted.isEmpty ? Color.secondary : KaisolaTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(QuietPressStyle()).disabled(pasted.isEmpty)
            if QRScannerView.isSupported {
                Button("Scan with camera instead") { showPaste = false }
                    .font(.subheadline.weight(.medium)).foregroundStyle(KaisolaTheme.accent).frame(maxWidth: .infinity)
            }
        }
    }

    private func progressStep(_ label: String) -> some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large).tint(KaisolaTheme.accent)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func confirmStep(_ sas: CompanionSAS) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 34)).foregroundStyle(KaisolaTheme.accent)
            Text("Confirm these words")
                .font(.title3.weight(.semibold))
            Text("Your Mac shows the same four words. Match them, then confirm on both.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(sas.words, id: \.self) { word in
                    Text(word)
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            HStack(spacing: 10) {
                Button("They differ") { coordinator.cancelPairing(); dismiss() }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 50)
                    .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .foregroundStyle(.primary)
                Button("They match") { coordinator.confirmSAS() }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(KaisolaTheme.darkFrame)
                    .background(KaisolaTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(QuietPressStyle())
        }
    }

    private var pairedStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46)).foregroundStyle(KaisolaTheme.done)
            Text("Paired").font(.title2.weight(.semibold))
            Text("Your Mac's sessions will appear on Home.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func scan(_ code: String) {
        guard let data = code.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CompanionPairingPayload.self, from: data) else {
            Task { @MainActor in coordinator.reportInvalidCode() }
            return
        }
        Task { await coordinator.pair(with: payload) }
    }
}
