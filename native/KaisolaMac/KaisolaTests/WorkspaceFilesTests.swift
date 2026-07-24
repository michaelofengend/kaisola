import Foundation
import XCTest
@testable import KaisolaMacPreview

/// ProjectFiles (tree listing + bounded enumeration) and FilePreviewContent
/// (what a file renders as) — the workspace rail's foundations.
final class WorkspaceFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-ws-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "swift".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "junk".write(to: root.appendingPathComponent("node_modules/dep/index.js"), atomically: true, encoding: .utf8)
        try ".hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChildrenSkipsIgnoredAndHiddenAndSortsDirsFirst() {
        let children = ProjectFiles.children(of: root)
        XCTAssertEqual(children.map(\.name), ["src", "README.md"])
        XCTAssertTrue(children[0].isDirectory)
    }

    func testEnumerateReturnsRelativePathsExcludingIgnored() {
        let files = ProjectFiles.enumerate(root: root)
        XCTAssertEqual(Set(files), ["README.md", "src/main.swift"])
    }

    func testEnumerateHonorsTheLimit() throws {
        for index in 0..<20 {
            try "x".write(to: root.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(ProjectFiles.enumerate(root: root, limit: 5).count, 5)
    }

    func testPreviewContentClassifiesFiles() throws {
        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("README.md")), .markdown("hello"))
        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("src/main.swift")), .text("swift"))

        let html = root.appendingPathComponent("preview.html")
        try "<h1>Hello</h1>".write(to: html, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePreviewContent.load(url: html), .html("<h1>Hello</h1>"))

        let binary = root.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x81]).write(to: binary)
        XCTAssertEqual(FilePreviewContent.load(url: binary), .binary)

        let image = root.appendingPathComponent("pic.png")
        try Data([0x89, 0x50]).write(to: image)
        XCTAssertEqual(FilePreviewContent.load(url: image), .image)

        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("missing.txt")), .unreadable)
    }

    func testDocxClassificationAndRichTextRoundTrip() throws {
        let file = root.appendingPathComponent("notes.docx")
        let source = NSAttributedString(string: "Editable native document")
        try RichDocumentIO.write(source, to: file)

        XCTAssertEqual(FilePreviewContent.load(url: file), .docx)
        XCTAssertEqual(
            RichDocumentIO.load(url: file)?.value.string.trimmingCharacters(in: .newlines),
            source.string
        )
    }

    func testOversizedFileReportsTooLarge() throws {
        let big = root.appendingPathComponent("big.txt")
        let bytes = FilePreviewContent.maxTextBytes + 1
        try Data(repeating: 0x61, count: bytes).write(to: big)
        XCTAssertEqual(FilePreviewContent.load(url: big), .tooLarge(bytes))
    }

    func testPreviewDetectsAnExternalEditBeforeSaving() throws {
        let file = root.appendingPathComponent("external-edit.txt")
        try "first".write(to: file, atomically: true, encoding: .utf8)
        let openedAt = FilePreviewDiskState.modificationDate(of: file)
        XCTAssertFalse(FilePreviewDiskState.changed(onDisk: file, since: openedAt))

        try "agent edit".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: file.path
        )
        XCTAssertTrue(FilePreviewDiskState.changed(onDisk: file, since: openedAt))
    }

    func testMarkdownRenderFallsBackToPlainText() {
        // Even degenerate input must yield a string, never a blank preview.
        let rendered = FilePreviewView.renderMarkdown("plain **bold** text")
        XCTAssertFalse(String(rendered.characters).isEmpty)
    }

    func testMarkdownDocumentPreservesBlockStructure() {
        let document = MarkdownDocument.parse("""
        # Heading

        Paragraph with **bold** text.

        - first
        1. second

        > quoted

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | --- | --- |
        | alpha | 1 |
        """)

        XCTAssertTrue(document.blocks.contains(.heading(level: 1, text: "Heading")))
        XCTAssertTrue(document.blocks.contains(.listItem(indent: 0, marker: "•", text: "first")))
        XCTAssertTrue(document.blocks.contains(.listItem(indent: 0, marker: "1.", text: "second")))
        XCTAssertTrue(document.blocks.contains(.quote("quoted")))
        XCTAssertTrue(document.blocks.contains(.code(language: "swift", text: "let answer = 42")))
        XCTAssertTrue(document.blocks.contains(.table(headers: ["Name", "Value"], rows: [["alpha", "1"]])))
    }

    func testMarkdownDocumentTranslatesCommonReadmeHTMLWithoutShowingTags() {
        let document = MarkdownDocument.parse("""
        <p align="center">
          <img src="icon.png" alt="Kaisola icon" />
        </p>

        <h1 align="center">Kaisola</h1>

        <p align="center">
          <strong>Your agents. One workspace.</strong><br />
          <a href="https://kaisola.com">Website</a> · Docs
        </p>
        """)

        XCTAssertEqual(document.blocks.first, .heading(level: 1, text: "Kaisola"))
        XCTAssertTrue(document.blocks.contains(.paragraph(
            "**Your agents. One workspace.** [Website](https://kaisola.com) · Docs"
        )))
        XCTAssertFalse(document.blocks.contains { block in String(describing: block).contains("<") })
    }

    func testMarkdownImageImportCreatesPortableAssetsWithoutOverwriting() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let markdown = docs.appendingPathComponent("Design Notes.md")
        try "# Design".write(to: markdown, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("My Diagram.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try bytes.write(to: source)

        let first = MarkdownAssetStore.importImages(
            [.file(source)],
            markdownURL: markdown,
            workspaceRoot: root
        )
        XCTAssertTrue(first.errors.isEmpty)
        XCTAssertEqual(first.insertions.map(\.markdown), [
            "![my-diagram](assets/design-notes/my-diagram.png)",
        ])
        XCTAssertEqual(try Data(contentsOf: first.insertions[0].fileURL), bytes)

        let second = MarkdownAssetStore.importImages(
            [.file(source)],
            markdownURL: markdown,
            workspaceRoot: root
        )
        XCTAssertTrue(second.errors.isEmpty)
        XCTAssertEqual(second.insertions.map(\.markdown), [
            "![my-diagram](assets/design-notes/my-diagram-2.png)",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.insertions[0].fileURL.path))
    }

    func testMarkdownImageImportRefusesDocumentsOutsideWorkspace() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-outside-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let markdown = outside.appendingPathComponent("notes.md")
        try "notes".write(to: markdown, atomically: true, encoding: .utf8)

        let batch = MarkdownAssetStore.importImages(
            [.data(Data([1, 2, 3]), suggestedName: "paste", fileExtension: "png")],
            markdownURL: markdown,
            workspaceRoot: root
        )

        XCTAssertTrue(batch.insertions.isEmpty)
        XCTAssertEqual(batch.errors.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("assets").path))
    }

    func testMarkdownImageImportDoesNotFollowAssetSymlinkOutsideWorkspace() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let markdown = docs.appendingPathComponent("notes.md")
        try "notes".write(to: markdown, atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-assets-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: docs.appendingPathComponent("assets", isDirectory: true),
            withDestinationURL: outside
        )

        let batch = MarkdownAssetStore.importImages(
            [.data(Data([1, 2, 3]), suggestedName: "paste", fileExtension: "png")],
            markdownURL: markdown,
            workspaceRoot: root
        )

        XCTAssertTrue(batch.insertions.isEmpty)
        XCTAssertEqual(batch.errors.count, 1)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    func testMarkdownEditingStyleFindsDocumentSemanticsWithoutRewritingSource() {
        let source = """
        # Heading

        **bold** and *italic* with `code` and [link](https://example.com).

        > quoted

        ```swift
        let answer = 42
        ```
        """
        let spans = MarkdownEditingStyle.spans(in: source)

        XCTAssertTrue(spans.contains { $0.role == .heading(1) })
        XCTAssertTrue(spans.contains { $0.role == .bold })
        XCTAssertTrue(spans.contains { $0.role == .italic })
        XCTAssertTrue(spans.contains { $0.role == .inlineCode })
        XCTAssertTrue(spans.contains { $0.role == .link })
        XCTAssertTrue(spans.contains { $0.role == .quote })
        XCTAssertTrue(spans.contains { $0.role == .codeBlock })
        XCTAssertEqual(source, """
        # Heading

        **bold** and *italic* with `code` and [link](https://example.com).

        > quoted

        ```swift
        let answer = 42
        ```
        """)
    }

    func testMarkdownEditingStyleCollapsesReadmeHTMLButStylesItsText() {
        let source = #"<h1 align="center">Kaisola</h1> <strong>One workspace.</strong> <a href="https://kaisola.com">Website</a>"#
        let spans = MarkdownEditingStyle.spans(in: source)

        XCTAssertTrue(spans.contains { $0.role == .heading(1) })
        XCTAssertTrue(spans.contains { $0.role == .bold })
        XCTAssertTrue(spans.contains { $0.role == .link })
        XCTAssertTrue(spans.contains { $0.role == .centered })
        XCTAssertGreaterThanOrEqual(spans.filter { $0.role == .syntax }.count, 6)
        XCTAssertEqual(source, #"<h1 align="center">Kaisola</h1> <strong>One workspace.</strong> <a href="https://kaisola.com">Website</a>"#)
    }

    func testHTMLPreviewPromptsForScriptOnlyAppShells() {
        XCTAssertTrue(HTMLPreviewReadiness.requiresJavaScriptPrompt("""
        <!doctype html><html><body><div id="root"></div><script src="app.js"></script></body></html>
        """))
        XCTAssertFalse(HTMLPreviewReadiness.requiresJavaScriptPrompt("""
        <!doctype html><html><body><h1>Static report</h1><script src="enhance.js"></script></body></html>
        """))
        XCTAssertFalse(HTMLPreviewReadiness.requiresJavaScriptPrompt("""
        <!doctype html><html><body><img src="chart.png"><script src="enhance.js"></script></body></html>
        """))
    }

    func testDirectorySymlinkIsNotRecursivelyIndexed() throws {
        let loop = root.appendingPathComponent("loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: root)
        XCTAssertFalse(ProjectFiles.children(of: root).contains { $0.name == "loop" })
        XCTAssertEqual(Set(ProjectFiles.enumerate(root: root)), ["README.md", "src/main.swift"])
    }
}
