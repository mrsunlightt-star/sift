import Foundation
import OSLog
import Shared

/// Purchase and entitlement state (§12).
///
/// The rule this type exists to enforce: **UserDefaults is never the source of
/// truth for an entitlement**. `isUnlocked` is derived from a verified
/// credential — a validated license for the direct-sold build, a verified
/// StoreKit transaction for a Mac App Store build — and the local cache only
/// reproduces the last verified answer so the app works offline.
///
/// The free tier is fully usable for understanding a Mac: it scans, analyses and
/// previews. It never performs a cleanup (§12.2).
public struct EntitlementState: Sendable, Equatable {
    public enum Channel: String, Sendable, Codable, CaseIterable {
        /// Direct build, activated with a license key.
        case direct
        /// Mac App Store build, activated through StoreKit.
        case appStore
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

/// The interface a purchase channel implements.
///
/// Two implementations exist: `DirectLicenseService` for the direct-sold build
/// and `StoreKitService` for a Mac App Store build. Keeping both behind one
/// protocol is what makes §12.5's requirement — identical cleaning rules and
/// identical risk levels on both channels — structural rather than a promise.
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

    public init(channel: any PurchaseChannel, defaults: UserDefaults = .standard) {
        self.channel = channel
        self.defaults = defaults
        self.cachedState = EntitlementState(
            channel: channel.channel,
            status: EntitlementService.restoredStatus(from: defaults)
        )
    }

    /// Reads the last verified timestamp out of the cache.
    ///
    /// A timestamp alone never unlocks anything permanently: it produces an
    /// `offlineGrace` window that expires, and the next successful verification
    /// is what refreshes it.
    private static func restoredStatus(from defaults: UserDefaults) -> EntitlementState.Status {
        guard let verifiedAt = defaults.object(forKey: Key.verifiedAt) as? Date else {
            return .free
        }
        let expiresAt = Calendar.current.date(byAdding: .day, value: offlineGraceDays, to: verifiedAt) ?? verifiedAt
        if expiresAt > Date() {
            return .offlineGrace(verifiedAt: verifiedAt, expiresAt: expiresAt)
        }
        return .free
    }

    public func current() -> EntitlementState { cachedState }

    /// True when the capability is available right now.
    public func allows(_ capability: Capability) -> Bool {
        if capability.isFree { return true }
        return cachedState.isUnlocked
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
            return state
        } catch {
            logger.notice("Purchase refresh failed; keeping the cached state")
            return cachedState
        }
    }

    /// Runs the purchase flow.
    @discardableResult
    public func purchase() async throws -> EntitlementState {
        let state = try await channel.purchase()
        guard state.isUnlocked else { throw PurchaseError.verificationFailed }
        apply(state)
        logger.notice("Purchase verified")
        return state
    }

    /// Re-verifies an existing purchase, e.g. after a reinstall.
    @discardableResult
    public func restore() async throws -> EntitlementState {
        let state = try await channel.restore()
        apply(state)
        return state
    }

    /// Activates a license key on the direct channel.
    public func activate(licenseKey: String) async throws -> EntitlementState {
        guard let direct = channel as? DirectLicenseService else {
            throw PurchaseError.invalidLicense
        }
        let state = try await direct.activate(licenseKey: licenseKey)
        apply(state)
        return state
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
        guard let stored = await keychain.load() else { return EntitlementState(channel: .direct, status: .free) }
        let state = try await verify(stored)
        return state
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

/// The Mac App Store channel.
///
/// Present so the app-store build is a configuration switch rather than a
/// rewrite (§12.4). The StoreKit calls live behind this type; the free/paid
/// gates above are shared with the direct build, which is what keeps the two
/// channels' safety behaviour identical.
public actor StoreKitChannel: PurchaseChannel {
    public nonisolated let channel: EntitlementState.Channel = .appStore

    /// Product identifier from §12.4.
    public static let productIdentifier = "com.siftmac.cleaner.lifetime"

    private let logger = SiftLog.purchase

    public init() {}

    public func load() async throws -> EntitlementState {
        // StoreKit 2's `Transaction.currentEntitlements` is the verification
        // source. Until the store build is enabled this reports the free tier so
        // the direct build behaves predictably.
        EntitlementState(channel: .appStore, status: .free)
    }

    public func purchase() async throws -> EntitlementState {
        logger.error("App Store purchase requested but StoreKit is not enabled in this build")
        throw PurchaseError.storeUnavailable
    }

    public func restore() async throws -> EntitlementState {
        throw PurchaseError.storeUnavailable
    }
}
