import Foundation
import XCTest
@testable import Core
import Shared

/// An in-memory licence store.
///
/// The tests must not reach the login keychain: a write from one test became a
/// Keychain authorisation prompt in the next, which blocked the Xcode test host
/// indefinitely.
private actor InMemoryLicenseStore: LicenseKeyStoring {
    private var key: String?

    func hasStoredKey() -> Bool { key != nil }
    func save(_ value: String) { key = value }
    func load() -> String? { key }
    func clear() { key = nil }
}

/// Purchase gates and the offline grace period (§12, §16.1).
final class EntitlementTests: XCTestCase, @unchecked Sendable {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "sift.tests.entitlement.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func makeService(verify: @escaping DirectLicenseService.Verify) -> EntitlementService {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return EntitlementService(
            channel: DirectLicenseService(keychain: InMemoryLicenseStore(), verify: verify),
            defaults: defaults
        )
    }

    func test_freeTierCanScanAndPreview() async {
        let service = makeService { _ in throw PurchaseError.licenseServiceUnavailable }
        for capability in [EntitlementService.Capability.scan, .analyzeStorage, .previewResults, .previewReports] {
            let allowed = await service.allows(capability)
            XCTAssertTrue(allowed, "\(capability.rawValue) must be free")
        }
    }

    func test_freeTierCannotCleanOrUninstall() async {
        let service = makeService { _ in throw PurchaseError.licenseServiceUnavailable }
        for capability in [
            EntitlementService.Capability.cleanJunk,
            .uninstallApplications,
            .cleanFiles,
            .batchOperations,
            .exportReports,
        ] {
            let allowed = await service.allows(capability)
            XCTAssertFalse(allowed, "\(capability.rawValue) requires a purchase")
        }
    }

    func test_aVerifiedLicenseUnlocksEverything() async {
        let service = makeService { key in
            XCTAssertEqual(key, "SIFT-TEST-KEY")
            return EntitlementState(channel: .direct, status: .unlocked(verifiedAt: Date()))
        }
        _ = try? await service.activate(licenseKey: "SIFT-TEST-KEY")
        let allowed = await service.allows(.cleanJunk)
        XCTAssertTrue(allowed)
    }

    func test_anEmptyKeyIsRejected() async {
        let service = makeService { _ in EntitlementState(channel: .direct, status: .free) }
        do {
            _ = try await service.activate(licenseKey: "   ")
            XCTFail("an empty key must be rejected")
        } catch let error as PurchaseError {
            XCTAssertEqual(error, .invalidLicense)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_aFailedVerificationLeavesTheFreeTierIntact() async {
        let service = makeService { _ in throw PurchaseError.licenseServiceUnavailable }
        let state = await service.refresh()
        XCTAssertFalse(state.isUnlocked)
        // A verification failure must never break what the user can already do.
        let scanAllowed = await service.allows(.scan)
        XCTAssertTrue(scanAllowed)
    }

    func test_aFailedVerificationDoesNotDowngradeAGracePeriod() async {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(Date(), forKey: "purchase.verifiedAt")

        // A stored key is what makes the channel *try* to verify. Without one,
        // `load()` reports the free tier without contacting anything, and a
        // "failed verification" never happens. This test used to rely on a
        // previous test having written a key to the login keychain.
        let store = InMemoryLicenseStore()
        await store.save("SIFT-TEST-KEY")
        let service = EntitlementService(
            channel: DirectLicenseService(keychain: store) { _ in
                throw PurchaseError.licenseServiceUnavailable
            },
            defaults: defaults
        )
        let state = await service.refresh()
        XCTAssertTrue(state.isUnlocked, "the offline window must survive an unreachable service")
        XCTAssertNotNil(state.status.graceDaysRemaining)
    }

    func test_anExpiredGracePeriodFallsBackToFree() async {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let longAgo = Date().addingTimeInterval(-Double(EntitlementService.offlineGraceDays + 1) * 86_400)
        defaults.set(longAgo, forKey: "purchase.verifiedAt")

        let service = EntitlementService(
            channel: DirectLicenseService(keychain: InMemoryLicenseStore()) { _ in
                throw PurchaseError.licenseServiceUnavailable
            },
            defaults: defaults
        )
        let state = await service.current()
        XCTAssertFalse(state.isUnlocked, "an expired window must not keep unlocking")
    }

    func test_removingAStoredLicenseReturnsToTheFreeTier() async {
        // The way out of a keychain item the app can no longer read, which is
        // what an ad-hoc build leaves behind after a rebuild.
        let store = InMemoryLicenseStore()
        await store.save("SIFT-TEST-KEY")
        let service = EntitlementService(
            channel: DirectLicenseService(keychain: store) { _ in
                EntitlementState(channel: .direct, status: .unlocked(verifiedAt: Date()))
            },
            defaults: UserDefaults(suiteName: suiteName) ?? .standard
        )

        let storedBefore = await service.hasStoredLicense()
        XCTAssertTrue(storedBefore)
        let state = await service.removeStoredLicense()

        XCTAssertFalse(state.isUnlocked)
        let stillStored = await service.hasStoredLicense()
        let remaining = await store.load()
        XCTAssertFalse(stillStored)
        XCTAssertNil(remaining, "the stored key is gone")
    }

    func test_priceFallsBackToTheReferenceAmount() {
        let state = EntitlementState(channel: .direct, status: .free)
        XCTAssertFalse(state.formattedPrice.isEmpty)
        XCTAssertTrue(
            state.formattedPrice.contains("4") || state.formattedPrice.contains("4.99"),
            "the reference price is $4.99"
        )
    }
}
