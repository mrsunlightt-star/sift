import Foundation
import OSLog
import ServiceManagement

/// "Open Sift at login", backed by the system's own registration.
///
/// `AppSettings.launchAtLogin` has been stored since the first build and nothing
/// ever read or wrote the system's login item, so the switch would have been a
/// lie in either direction. `SMAppService.mainApp` is the supported API on
/// macOS 13+: the system owns the registration, an app cannot read it from
/// `UserDefaults`, and a switch bound to a stored boolean drifts the moment the
/// user removes the item in System Settings.
///
/// The status is therefore read from the system every time and never cached.
public enum LoginItem {
    private static let logger = SiftLog.ui

    /// False in a package build and in tests, where there is no installed app to
    /// register. The settings row hides itself rather than offering a switch
    /// that cannot work.
    public static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
    }

    public static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the state the system ended up in, not the state that was asked
    /// for: a refused registration must not leave the switch showing "on".
    @discardableResult
    public static func set(enabled: Bool) -> Bool {
        guard isSupported else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("The login item could not be changed (error=\(error.localizedDescription, privacy: .public))")
        }
        return isEnabled
    }
}
