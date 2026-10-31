import Foundation
import OSLog
import Shared

/// Purchase and entitlement state (§12).
///
/// The rule this type exists to enforce: **UserDefaults is never the source of
/// truth for an entitlement**. `isUnlocked` is derived from a validated license
/// key, and the local cache only reproduces the last verified answer so the app
/// works offline.
///
/// The free tier is fully usable for understanding a Mac: it scans, analyses and
/// previews. It never performs a cleanup (§12.2).
public struct EntitlementState: Sendable, Equatable {
    public enum Channel: String, Sendable, Codable, CaseIterable {
        /// The only distribution channel: a direct download activated with a
        /// license key. There is no Mac App Store build — App Sandbox cannot
        /// scan the home Library — so no second channel is modelled.
        case direct
    }

    public enum Status: Sendable, Equatable {
        /// Not purchased, or the credential could not be verified.
        case free
        /// Verified as purchased.
        case unlocked(verifiedAt: Date)
        /// Previously verified, and the service is unreachable right now.
        case offlineGrace(verifiedAt: Date, expiresAt: Date)

        public var isUnlocked: Bool {
            switch self {
            case .free: false
            case .unlocked, .offlineGrace: true
            }
        }

        public var graceDaysRemaining: Int? {
            guard case let .offlineGrace(_, expiresAt) = self else { return nil }
            return max(Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0, 0)
        }
    }

    public let channel: Channel
    public let status: Status
    /// The localized price reported by the store, when known.
    public let localizedPrice: String?
    public let currencyCode: String?

    public init(channel: Channel, status: Status, localizedPrice: String? = nil, currencyCode: String? = nil) {
        self.channel = channel
        self.status = status
        self.localizedPrice = localizedPrice
        self.currencyCode = currencyCode
    }

    public var isUnlocked: Bool { status.isUnlocked }

    /// The reference price from the specification, used until a channel reports
    /// its own localised amount.
    public static let referencePrice = Decimal(string: "4.99") ?? 4.99

    public var formattedPrice: String {
        if let localizedPrice { return localizedPrice }
        return SiftFormat.price(Self.referencePrice, currencyCode: currencyCode ?? "USD")
    }
}

/// Errors the purchase flow can raise, mapped to the product error table (§14).
public enum PurchaseError: Error, Sendable, Equatable {
    case licenseServiceUnavailable
    case storeUnavailable
    case invalidLicense
    case verificationFailed
    case cancelled

    public var code: ErrorCode {
        switch self {
        case .licenseServiceUnavailable, .invalidLicense, .verificationFailed:
            .licenseServiceUnavailable
        case .storeUnavailable:
            .storeUnavailable
        case .cancelled:
            .cancelled
        }
    }

    public var message: String {
        switch self {
        case .licenseServiceUnavailable, .verificationFailed:
            LocalizationKey.purchaseNetworkUnavailable.localized
        case .storeUnavailable:
            LocalizationKey.purchaseFailed.localized
        case .invalidLicense:
            LocalizationKey.purchaseFailed.localized
        case .cancelled:
            LocalizationKey.scanPhaseCancelled.localized
        }
    }
}

/// The interface the direct license channel implements.
///
/// Kept as a protocol so the entitlement logic is testable with an injected
/// verifier and so a future distribution decision would not touch the gates.
public protocol PurchaseChannel: Sendable {
    var channel: EntitlementState.Channel { get }
    /// Loads the localised price and any cached credential.
    func load() async throws -> EntitlementState
    /// Starts a purchase.
    func purchase() async throws -> EntitlementState
    /// Re-verifies an existing entitlement.
    func restore() async throws -> EntitlementState
}

/// Decides what the user is allowed to do.
///
/// Every gate in the UI goes through `allows(_:)` so the free/paid boundary is
/// described once. The gates are deliberately late: the paywall appears when the
/// user clicks Clean or Uninstall, never at launch (§12.2).
public actor EntitlementService {
    /// Capabilities the app gates on a purchase.
    public enum Capability: String, Sendable, CaseIterable {
        case scan
        case analyzeStorage
        case previewResults
        case previewReports
        case cleanJunk
        case uninstallApplications
        case cleanFiles
        case batchOperations
        case exportReports

        /// True for the capabilities the free tier includes.
        public var isFree: Bool {
            switch self {
            case .scan, .analyzeStorage, .previewResults, .previewReports: true
            case .cleanJunk, .uninstallApplications, .cleanFiles, .batchOperations, .exportReports: false
            }
        }
    }

    private let channel: any PurchaseChannel
    private let defaults: UserDefaults
    /// The clock every window is measured against.
    ///
    /// Injected so the one case that matters can be tested without waiting two
    /// weeks: an app that stays open past the end of its offline grace period.
    private let now: @Sendable () -> Date
    private let logger = SiftLog.purchase
    private var cachedState: EntitlementState

    /// Offline grace period for a direct license (§12.3). The duration is an open
    /// item in the spec; 14 days is the value this build uses and it is recorded
    /// in the settings privacy note.
    public static let offlineGraceDays = 14

    private enum Key {
        static let verifiedAt = "purchase.verifiedAt"
        static let channel = "purchase.channel"
    }

    /// How far into the future a verification timestamp may sit and still count.
    ///
    /// A clock corrected by NTP between the verification and the next launch can
    /// put the stored instant slightly ahead; anything further ahead is not a
    /// verification at all, and treating it as one would move the end of the
    /// window forward by however far the clock was pushed.
    public static let clockSkewTolerance: TimeInterval = 300

    public init(
        channel: any PurchaseChannel,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.channel = channel
        self.defaults = defaults
        self.now = now
        self.cachedState = EntitlementState(
            channel: channel.channel,
            status: EntitlementService.restoredStatus(
                from: defaults,
                channel: channel.channel,
                now: now()
            )
        )
    }

    /// Reads the last verified timestamp out of the cache.
    ///
    /// A timestamp alone never unlocks anything permanently: it produces an
    /// `offlineGrace` window that expires, and the next successful verification
    /// is what refreshes it.
    ///
    /// The cache belongs to the channel that wrote it. A timestamp left under a
    /// different channel name — an older build, or a distribution decision that
    /// changed — is ignored rather than carried across: the executable and its
    /// `UserDefaults` domain can be reused by a build whose purchase model is
    /// different.
    private static func restoredStatus(
        from defaults: UserDefaults,
        channel: EntitlementState.Channel,
        now: Date
    ) -> EntitlementState.Status {
        guard defaults.string(forKey: Key.channel) == channel.rawValue else {
            return .free
        }
        guard let verifiedAt = defaults.object(forKey: Key.verifiedAt) as? Date else {
            return .free
        }
        guard verifiedAt <= now.addingTimeInterval(clockSkewTolerance) else {
            return .free
        }
        let expiresAt = Calendar.current.date(byAdding: .day, value: offlineGraceDays, to: verifiedAt) ?? verifiedAt
        if expiresAt > now {
            return .offlineGrace(verifiedAt: verifiedAt, expiresAt: expiresAt)
        }
        return .free
    }

    /// The state as it stands at `now`.
    ///
    /// An offline window is measured against the clock, not against the moment
    /// the process started. `refresh()` cannot be what enforces it: the refresh
    /// only runs when the channel answers, and a lease that stops being verified
    /// is exactly the case where it does not. A Mac left open past the end of the
    /// window therefore stops being unlocked without being relaunched.
    private func evaluated(_ state: EntitlementState) -> EntitlementState {
        guard case let .offlineGrace(_, expiresAt) = state.status, expiresAt <= now() else {
            return state
        }
        return EntitlementState(
            channel: state.channel,
            status: .free,
            localizedPrice: state.localizedPrice,
            currencyCode: state.currencyCode
        )
    }

    public func current() -> EntitlementState { evaluated(cachedState) }

    /// True when the capability is available right now.
    public func allows(_ capability: Capability) -> Bool {
        if capability.isFree { return true }
        return evaluated(cachedState).isUnlocked
    }

    /// Refreshes the entitlement from the channel.
    ///
    /// A failure never downgrades an active offline grace: the specification
    /// requires a license-verification failure not to break the app (§12.3).
    @discardableResult
    public func refresh() async -> EntitlementState {
        do {
            let state = try await channel.load()
            apply(state)
            return evaluated(state)
        } catch {
            logger.notice("Purchase refresh failed; keeping the cached state")
            return evaluated(cachedState)
        }
    }

    /// True when a licence key is stored on this machine.
    public func hasStoredLicense() async -> Bool {
        guard let direct = channel as? DirectLicenseService else { return false }
        return await direct.hasStoredLicense()
    }

    /// The stored licence key with its middle groups masked, for the account page.
    ///
    /// The page shows only enough of the key to tell two keys apart; the whole
    /// secret never appears in the interface, and therefore never in a
    /// screenshot a user shares.
    public func maskedLicenseKey() async -> String? {
        guard let direct = channel as? DirectLicenseService else { return nil }
        guard let key = await direct.currentLicenseKey() else { return nil }
        return Self.maskedLicenseKey(key)
    }

    /// `SIFT-DEV-K7QM-3XPD-8R2V` → `SIFT-•••-•••-•••-8R2V`.
    ///
    /// The first and the last group stay readable and every group in between is
    /// replaced dot for dot, so the display keeps the key's length and shape
    /// without carrying its content. A key whose shape is not hyphen-grouped
    /// keeps only its last four characters.
    public static func maskedLicenseKey(_ key: String) -> String {
        let groups = key.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count > 2 else {
            guard key.count > 4 else { return String(repeating: "•", count: key.count) }
            return String(repeating: "•", count: key.count - 4) + key.suffix(4)
        }
        let masked = groups.enumerated().map { index, group in
            index == 0 || index == groups.count - 1
                ? String(group)
                : String(repeating: "•", count: group.count)
        }
        return masked.joined(separator: "-")
    }

    /// Removes the stored key and returns to the free tier.
    @discardableResult
    public func removeStoredLicense() async -> EntitlementState {
        guard let direct = channel as? DirectLicenseService else { return cachedState }
        await direct.clearStoredLicense()
        let state = EntitlementState(channel: channel.channel, status: .free)
        apply(state)
        return evaluated(state)
    }

    /// Runs the purchase flow.
    @discardableResult
    public func purchase() async throws -> EntitlementState {
        let state = try await channel.purchase()
        guard state.isUnlocked else { throw PurchaseError.verificationFailed }
        apply(state)
        logger.notice("Purchase verified")
        return evaluated(state)
    }

    /// Re-verifies an existing purchase, e.g. after a reinstall.
    @discardableResult
    public func restore() async throws -> EntitlementState {
        let state = try await channel.restore()
        apply(state)
        return evaluated(state)
    }

    /// Activates a license key on the direct channel.
    public func activate(licenseKey: String) async throws -> EntitlementState {
        guard let direct = channel as? DirectLicenseService else {
            throw PurchaseError.invalidLicense
        }
        let state = try await direct.activate(licenseKey: licenseKey)
        apply(state)
        return evaluated(state)
    }

    private func apply(_ state: EntitlementState) {
        cachedState = state
        defaults.set(state.channel.rawValue, forKey: Key.channel)
        switch state.status {
        case let .unlocked(verifiedAt), let .offlineGrace(verifiedAt, _):
            defaults.set(verifiedAt, forKey: Key.verifiedAt)
        case .free:
            defaults.removeObject(forKey: Key.verifiedAt)
        }
    }
}

/// The direct-sold license service.
///
/// The network calls are deliberately not implemented here: the spec leaves the
/// vendor open (§19), so this type defines the contract and the offline
/// behaviour while the transport is a single injectable closure. That keeps the
/// entitlement logic testable without a network, and makes "which vendor" a
/// one-line decision later.
public actor DirectLicenseService: PurchaseChannel {
    public nonisolated let channel: EntitlementState.Channel = .direct

    /// Performs a server-side verification. Returns the verified state.
    public typealias Verify = @Sendable (String) async throws -> EntitlementState

    private let verify: Verify
    private var licenseKey: String?
    private let keychain: any LicenseKeyStoring
    private let logger = SiftLog.purchase

    public init(keychain: any LicenseKeyStoring = LicenseKeyStore(), verify: @escaping Verify) {
        self.keychain = keychain
        self.verify = verify
    }

    /// True when a key is stored on this machine.
    public func hasStoredLicense() async -> Bool {
        await keychain.hasStoredKey()
    }

    /// Removes the stored key.
    ///
    /// A keychain item can outlive the build that wrote it: an ad-hoc-signed app
    /// has no stable identity, so macOS asks for permission again after every
    /// rebuild. Without this the prompt has no way out from inside the app.
    public func clearStoredLicense() async {
        await keychain.clear()
        licenseKey = nil
    }

    public func load() async throws -> EntitlementState {
        // Never touch the Keychain unless a key was stored. Reading it on a fresh
        // install raises a system password prompt before the user has bought
        // anything, which is exactly the kind of interruption §2.3 rules out.
        guard await keychain.hasStoredKey() else {
            return EntitlementState(channel: .direct, status: .free)
        }
        guard let stored = await keychain.load() else {
            return EntitlementState(channel: .direct, status: .free)
        }
        licenseKey = stored
        do {
            return try await verify(stored)
        } catch {
            // A transport failure is not a license failure: report the state the
            // caller already has so the offline window keeps working.
            throw PurchaseError.licenseServiceUnavailable
        }
    }

    public func activate(licenseKey: String) async throws -> EntitlementState {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PurchaseError.invalidLicense }
        let state = try await verify(trimmed)
        guard state.isUnlocked else { throw PurchaseError.invalidLicense }
        await keychain.save(trimmed)
        self.licenseKey = trimmed
        logger.notice("License activated")
        return state
    }

    public func purchase() async throws -> EntitlementState {
        throw PurchaseError.storeUnavailable
    }

    public func restore() async throws -> EntitlementState {
        // Same rule as `load()`: never touch the Keychain unless a key was
        // stored. Reading it on a machine that never bought anything raises a
        // system password prompt for a purchase that does not exist.
        guard await keychain.hasStoredKey() else {
            return EntitlementState(channel: .direct, status: .free)
        }
        guard let stored = await keychain.load() else {
            return EntitlementState(channel: .direct, status: .free)
        }
        return try await verify(stored)
    }

    /// The license key, for display masking in settings. Never logged.
    public func currentLicenseKey() async -> String? { licenseKey }
}

/// A minimal Keychain wrapper for the license key.
///
/// Stored in the Keychain rather than `UserDefaults` because a license key is a
/// credential: putting it in a plist the user can edit would make the offline
/// check trivially forgeable.
/// Where a licence key lives between launches.
///
/// A protocol so the tests can use an in-memory store. They used the real one
/// first, which meant `test_activationUnlocks` wrote a key into the login
/// keychain and the next test's read waited for a Keychain authorisation prompt
/// under the Xcode test host — a hang, not a failure. Tests must not touch a
/// user's keychain.
public protocol LicenseKeyStoring: Sendable {
    func hasStoredKey() async -> Bool
    func save(_ key: String) async
    func load() async -> String?
    func clear() async
}

public actor LicenseKeyStore: LicenseKeyStoring {
    private let service = "com.siftmac.cleaner.license"
    private let account = "license-key"
    /// Marker kept outside the Keychain, so the app can tell whether a key exists
    /// without triggering a Keychain prompt. It records only that a key was
    /// stored; the credential itself never leaves the Keychain.
    private let presenceKey = "purchase.hasStoredLicense"

    public init() {}

    /// True when a key has been stored by this app.
    public func hasStoredKey() -> Bool {
        UserDefaults.standard.bool(forKey: presenceKey)
    }

    public func save(_ key: String) {
        UserDefaults.standard.set(true, forKey: presenceKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: presenceKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A development-only key store: the licence key lives in the injected
/// defaults.
///
/// The real store is the Keychain, and the Keychain binds its access control to
/// the app's code signature. A development build is rebuilt constantly, and
/// each rebuild re-asked for the stored key no matter how many times it had
/// been allowed through — a prompt in the middle of every verification run.
/// The development key is not a secret (it is committed to this repository), so
/// the DEBUG build keeps it in defaults and the prompt disappears entirely.
/// The release build keeps `LicenseKeyStore` and its protection.
public actor DefaultsLicenseKeyStore: LicenseKeyStoring {
    private let keyKey = "purchase.developmentLicenseKey"
    private let presenceKey = "purchase.hasStoredLicense"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasStoredKey() -> Bool {
        defaults.bool(forKey: presenceKey)
    }

    public func save(_ key: String) {
        defaults.set(true, forKey: presenceKey)
        defaults.set(key, forKey: keyKey)
    }

    public func load() -> String? {
        defaults.string(forKey: keyKey)
    }

    public func clear() {
        defaults.removeObject(forKey: presenceKey)
        defaults.removeObject(forKey: keyKey)
    }
}
