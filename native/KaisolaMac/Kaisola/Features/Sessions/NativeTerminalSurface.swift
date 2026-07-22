import AppKit
import SwiftTerm
import SwiftUI

struct NativeTerminalSurface: NSViewRepresentable {
    let output: String
    let streamEpoch: String?
    let endOffset: Int64?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReadOnlyTerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = ReadOnlyTerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.allowMouseReporting = false
        view.linkReporting = .implicit
        view.optionAsMetaKey = false
        view.setAccessibilityLabel("Read-only terminal output")
        context.coordinator.apply(output: output, epoch: streamEpoch, endOffset: endOffset, to: view)
        return view
    }

    func updateNSView(_ view: ReadOnlyTerminalView, context: Context) {
        context.coordinator.apply(output: output, epoch: streamEpoch, endOffset: endOffset, to: view)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private var renderedEpoch: String?
        private var renderedStartOffset: Int64?
        private var renderedEndOffset: Int64?
        private var hasRendered = false

        @MainActor
        func apply(output: String, epoch: String?, endOffset: Int64?, to view: ReadOnlyTerminalView) {
            let outputBytes = Int64(output.utf8.count)
            let startOffset = endOffset.map { $0 - outputBytes }

            if !hasRendered {
                if !output.isEmpty { view.feed(text: output) }
                renderedEpoch = epoch
                renderedStartOffset = startOffset
                renderedEndOffset = endOffset
                hasRendered = true
                return
            }

            if epoch == renderedEpoch,
               let oldEnd = renderedEndOffset,
               let newEnd = endOffset,
               let newStart = startOffset,
               newStart >= 0,
               oldEnd >= newStart,
               newEnd >= oldEnd {
                if newEnd == oldEnd {
                    // A broker stream is immutable within an epoch. Equal byte
                    // bounds therefore mean SwiftTerm already has this view.
                    if newStart == renderedStartOffset { return }
                } else {
                    let bytesToSkip = oldEnd - newStart
                    if let suffix = outputSuffix(output, droppingUTF8Bytes: bytesToSkip),
                       Int64(suffix.utf8.count) == newEnd - oldEnd {
                        view.feed(text: suffix)
                        renderedStartOffset = newStart
                        renderedEndOffset = newEnd
                        return
                    }
                }
            }

            if epoch != renderedEpoch || startOffset != renderedStartOffset || endOffset != renderedEndOffset {
                view.getTerminal().resetToInitialState()
                if !output.isEmpty { view.feed(text: output) }
            }
            renderedEpoch = epoch
            renderedStartOffset = startOffset
            renderedEndOffset = endOffset
            hasRendered = true
        }

        private func outputSuffix(_ output: String, droppingUTF8Bytes count: Int64) -> String? {
            guard count >= 0, count <= Int64(output.utf8.count), let distance = Int(exactly: count) else {
                return nil
            }
            let utf8 = output.utf8
            let byteIndex = utf8.index(utf8.startIndex, offsetBy: distance)
            guard let stringIndex = byteIndex.samePosition(in: output) else { return nil }
            return String(output[stringIndex...])
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased()) else { return }
            NSWorkspace.shared.open(url)
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Drops both physical-key input and terminal-generated query replies. SwiftTerm
/// still provides native selection, copy, accessibility, and Command-F search,
/// but no byte can flow from this view back to a PTY.
final class ReadOnlyTerminalView: TerminalView {
    override func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
