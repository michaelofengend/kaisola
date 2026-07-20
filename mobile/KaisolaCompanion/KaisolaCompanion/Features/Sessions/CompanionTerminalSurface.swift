import SwiftTerm
import SwiftUI
import UIKit

/// UIKit terminal emulator hosted in SwiftUI. A replacement bounded snapshot
/// performs a full terminal reset; ordered suffixes are fed incrementally.
struct CompanionTerminalSurface: UIViewRepresentable {
    let output: String
    let streamEpoch: String?
    let controlEnabled: Bool
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeUIView(context: Context) -> CompanionSafeTerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = CompanionSafeTerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.linkReporting = .none
        view.allowMouseReporting = false
        var options = view.getTerminal().options
        options.enableSixelReported = false
        options.kittyImageCacheLimitBytes = 2 * 1024 * 1024
        view.getTerminal().options = options
        view.nativeBackgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.047, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.88, alpha: 1)
        view.caretColor = UIColor(red: 0.69, green: 0.77, blue: 0.35, alpha: 1)
        view.showsHorizontalScrollIndicator = false
        context.coordinator.apply(output: output, epoch: streamEpoch, to: view)
        return view
    }

    func updateUIView(_ view: CompanionSafeTerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.controlEnabled = controlEnabled
        context.coordinator.apply(output: output, epoch: streamEpoch, to: view)
        if controlEnabled && !context.coordinator.didFocusForCurrentLease {
            context.coordinator.didFocusForCurrentLease = true
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !controlEnabled {
            context.coordinator.didFocusForCurrentLease = false
            _ = view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: (Data) -> Void
        var onResize: (Int, Int) -> Void
        var controlEnabled = false
        var didFocusForCurrentLease = false
        private var renderedOutput = ""
        private var renderedEpoch: String?

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        @MainActor
        func apply(output: String, epoch: String?, to view: TerminalView) {
            guard output != renderedOutput || epoch != renderedEpoch else { return }
            if epoch != renderedEpoch || !output.hasPrefix(renderedOutput) {
                view.getTerminal().resetToInitialState()
                if !output.isEmpty { view.feed(text: output) }
            } else {
                let suffix = output.dropFirst(renderedOutput.count)
                if !suffix.isEmpty { view.feed(text: String(suffix)) }
            }
            renderedEpoch = epoch
            renderedOutput = output
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard controlEnabled, !data.isEmpty else { return }
            onInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard controlEnabled, newCols >= 20, newRows >= 5 else { return }
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm routes emulator-generated device/focus/query replies through this
/// method, while physical keyboard input uses `send(data:)` on the view. Never
/// let untrusted terminal output synthesize bytes back into the Mac PTY.
final class CompanionSafeTerminalView: TerminalView {
    override func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
