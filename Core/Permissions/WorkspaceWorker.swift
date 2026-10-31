import AppKit
import Foundation

/// The only place in `Core` that reaches into AppKit's workspace APIs.
///
/// Kept behind a small interface so the rest of the domain layer stays testable
/// without a running GUI, and so `MainActor` isolation is confined to one type
/// instead of leaking into view models.
@MainActor
final class NSWorkspaceWorker {
    static let shared = NSWorkspaceWorker()

    private init() {}

    /// Resolved paths of every running application bundle.
    func runningApplicationBundlePaths() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            application.bundleURL?
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
    }

    /// Asks the running application at `bundleURL` to quit.
    ///
    /// `terminate()` is a request: the application may prompt the user to save
    /// work. It reports `false` when no running instance matches or the request
    /// could not be sent, which is the case the caller has to tell the user about
    /// instead of leaving a button that did nothing.
    func terminateApplication(bundleURL: URL) -> Bool {
        let target = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let application = NSWorkspace.shared.runningApplications.first(where: { candidate in
            candidate.bundleURL?
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path == target
        }) else {
            return false
        }
        return application.terminate()
    }

    /// Opens a URL with the default handler, e.g. the Trash in the Finder.
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Opens a folder in the Finder and selects the item when it exists.
    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(parent)
        }
    }

    /// Opens the Privacy & Security pane of System Settings, where Full Disk
    /// Access lives (§10.2 step 3).
    func openFullDiskAccessSettings() {
        // The anchor that lands on the Full Disk Access list itself comes
        // first. The pane-level URL also opens successfully everywhere, so a
        // pane-level candidate that "works" hides the precise one behind a page
        // the user then has to find — exactly the confusion the button exists
        // to prevent.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.privacy?Privacy_AllFiles",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }
}

/// Workspace actions used by the UI, hop to the main actor internally.
public enum WorkspaceActions {
    /// Reveals a file or folder in the Finder.
    public static func reveal(_ url: URL) async {
        await MainActor.run { NSWorkspaceWorker.shared.reveal(url) }
    }

    /// Opens the Trash so the user can undo a cleanup (§5.2).
    public static func openTrash() async {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        await MainActor.run { _ = NSWorkspaceWorker.shared.open(trash) }
    }

    /// Opens the Full Disk Access pane.
    @MainActor public static func openFullDiskAccessSettings() async {
        await MainActor.run { NSWorkspaceWorker.shared.openFullDiskAccessSettings() }
    }

    /// True when an app bundle is currently running.
    public static func isApplicationRunning(bundlePath: URL) async -> Bool {
        let paths = await MainActor.run { NSWorkspaceWorker.shared.runningApplicationBundlePaths() }
        let target = bundlePath.standardizedFileURL.resolvingSymlinksInPath().path
        return paths.contains(target)
    }

    /// Asks the application at `bundlePath` to quit, reporting whether the request
    /// was sent.
    public static func quitApplication(bundlePath: URL) async -> Bool {
        await MainActor.run {
            NSWorkspaceWorker.shared.terminateApplication(bundleURL: bundlePath)
        }
    }
}
