import Foundation

/// One node in the workspace file tree.
struct FileNode: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Directory listing + project file enumeration for the workspace rail and the
/// command palette's file search. Pure filesystem logic, testable directly.
enum ProjectFiles {
    /// Directories that never belong in a tree or fuzzy index.
    static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", "dist", "DerivedData", ".swiftpm",
        "__pycache__", ".venv", ".next", ".turbo", "build",
    ]

    /// Immediate children of a directory: folders first, then files, both
    /// alphabetical; hidden entries and ignored directories skipped.
    static func children(of directory: URL) -> [FileNode] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let nodes = contents.compactMap { url -> FileNode? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory, ignoredNames.contains(url.lastPathComponent) { return nil }
            return FileNode(url: url.standardizedFileURL, isDirectory: isDirectory)
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Recursively enumerate project files for fuzzy search, bounded so a huge
    /// tree cannot stall the palette. Returns project-relative paths.
    static func enumerate(root: URL, limit: Int = 3_000) -> [String] {
        var results: [String] = []
        var queue: [URL] = [root]
        let rootPath = root.standardizedFileURL.path
        while !queue.isEmpty, results.count < limit {
            let directory = queue.removeFirst()
            for node in children(of: directory) {
                if node.isDirectory {
                    queue.append(node.url)
                } else {
                    let path = node.url.path
                    if path.hasPrefix(rootPath + "/") {
                        results.append(String(path.dropFirst(rootPath.count + 1)))
                        if results.count >= limit { break }
                    }
                }
            }
        }
        return results
    }
}

/// A small TTL cache of project file lists so the palette doesn't re-walk the
/// tree on every keystroke.
@MainActor
final class ProjectFileIndex {
    static let shared = ProjectFileIndex()
    private var cache: [String: (at: Date, files: [String])] = [:]

    func files(for root: URL, now: Date = Date()) -> [String] {
        let key = root.standardizedFileURL.path
        if let cached = cache[key], now.timeIntervalSince(cached.at) < 30 {
            return cached.files
        }
        let files = ProjectFiles.enumerate(root: root)
        cache[key] = (now, files)
        return files
    }

    func invalidate() {
        cache.removeAll()
    }
}
