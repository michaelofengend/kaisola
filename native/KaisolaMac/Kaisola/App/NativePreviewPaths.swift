import Darwin
import Foundation

enum NativePreviewPaths {
    static let applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.kaisola.mac.preview", isDirectory: true)

    static func prepareApplicationSupport() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(applicationSupportDirectory.path, 0o700)
    }
}
