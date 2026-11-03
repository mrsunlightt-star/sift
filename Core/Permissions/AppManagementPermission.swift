import Foundation
import OSLog

/// Whether macOS will let this app move another developer's application bundle.
///
/// Moving an application is not a file permission. `rename` of
/// `/Applications/CapCut.app` returns `EACCES` for a process that may write the
/// same directory, may read the bundle, and holds Full Disk Access — the gate is
/// App Management (`kTCCServiceSystemPolicyAppBundles`, Privacy & Security →
/// App Management). Measured on this machine, with tccd answering the same
/// process's Full Disk Access request `authValue=2` at the same moment.
///
/// macOS has no public query for a privacy decision, so this reads the stored
/// answer the same way the system does — `TCCAccessPreflight` in the private
/// TCC framework, loaded at runtime. Preflight never prompts; it reports the
/// decision that already exists, which is exactly the question. When the symbol
/// is missing or the answer is not one this build understands, the state is
/// `unknown` and nothing is claimed to the user: an answer that was not given
/// must not be turned into a banner.
public enum AppManagementStatus: Sendable, Equatable {
    /// Moving an application bundle is allowed.
    case granted
    /// The system will refuse; the switch can be turned on by the user.
    case denied
    /// Not answered: the framework, the symbol or the value was not available.
    case unknown

    /// The status a preflight return value states.
    ///
    /// `TCCAccessPreflightResult` is `unknown`/`denied`/`allowed` as 0/1/2.
    /// Anything else is not a verdict this build recognises, so it is reported
    /// as `unknown` rather than guessed into `denied` — a wrong banner on a
    /// permission the user already granted is worse than no banner.
    public static func from(preflight value: Int32?) -> AppManagementStatus {
        switch value {
        case 2: .granted
        case 1: .denied
        default: .unknown
        }
    }
}

/// Reads the App Management decision, and remembers what this session has
/// learned from real moves.
///
/// The probe answers the question before anything is attempted; the learned
/// value corrects it from behaviour, so a build that reads the wrong value from
/// a future framework cannot keep showing a switch the user already turned on —
/// a bundle that actually moved is proof the gate is open, and a refusal with
/// `appManagementRequired` is proof it is closed.
public struct AppManagementProbe: Sendable {
    /// The service whose decision is the one that matters here.
    public static let service = "kTCCServiceSystemPolicyAppBundles"

    private let logger = SiftLog.permissions

    public init() {}

    /// The stored decision, or `unknown`.
    public func status() -> AppManagementStatus {
        guard let raw = Self.preflight(service: Self.service) else {
            logger.info("App Management: the TCC preflight symbol is not available")
            return .unknown
        }
        let status = AppManagementStatus.from(preflight: raw)
        logger.debug("App Management preflight reported \(String(describing: status), privacy: .public)")
        return status
    }

    /// Calls `TCCAccessPreflight` if this system has it.
    ///
    /// `dlopen` at first use rather than a link-time dependency: the framework
    /// and the symbol are private, so a missing one has to degrade to "no
    /// answer", not to a launch failure.
    static func preflight(service: String) -> Int32? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        typealias Preflight = @convention(c) (CFString, CFDictionary?, UnsafeMutablePointer<Int32>?) -> Int32
        let call = unsafeBitCast(symbol, to: Preflight.self)
        // The signature moved the result into the return value on macOS 13+ and
        // left the out-parameter alone. Read both: the out-parameter when this
        // system writes it, the return value otherwise.
        var written: Int32 = -1
        let returned = call(service as CFString, nil, &written)
        if written >= 0 { return written }
        return returned
    }
}
