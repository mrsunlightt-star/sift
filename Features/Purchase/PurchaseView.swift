import Core
import Shared
import SwiftUI

/// The purchase page (§12).
///
/// Two things this page must get right, both stated in the specification: the
/// price line is exactly "$4.99 once, yours forever, no subscription", and the
/// free tier is described honestly — what it already does — rather than being
/// framed as a limitation.
public struct PurchaseView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let reason: PaywallReasonLink?
    @State private var licenseKey = ""
    @State private var isWorking = false
    @State private var maskedKey: String?
    @State private var message: (isError: Bool, text: String)?

    public init(reason: PaywallReasonLink? = nil) {
        self.reason = reason
    }

    private var isUnlocked: Bool { environment.entitlement.isUnlocked }

    public var body: some View {
        VStack(spacing: 0) {
            SiftPageHeader(title: pageTitle, status: headerStatus) {
                SiftMetricPill(
                    symbolName: isUnlocked ? "checkmark.seal.fill" : "lock.open",
                    value: (isUnlocked
                        ? LocalizationKey.purchaseStatusPurchased
                        : LocalizationKey.purchaseStatusFree).localized,
                    tint: isUnlocked ? SiftColor.safe : SiftColor.accent
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                    if isUnlocked {
                        accountSection
                    } else {
                        SiftHeroCard(
                            symbolName: "lock.open",
                            title: LocalizationKey.purchasePriceLine.localized,
                            detail: LocalizationKey.purchaseUpdatesPromise.localized,
                            tint: SiftColor.accent
                        ) {
                            EmptyView()
                        }

                        if let reason {
                            NoticeBanner(
                                level: .information,
                                message: "\(reason.titleKey.localized), \(LocalizationKey.purchaseLicenseRequiredDetail.localized)"
                            )
                        }

                        comparison
                        licenseSection
                    }
                    if let message {
                        NoticeBanner(
                            level: message.isError ? .warning : .success,
                            message: message.text
                        )
                    }
                    footer
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.vertical, SiftMetrics.pageSpacing)
                .frame(maxWidth: SiftMetrics.contentWidthStandard, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        // The masked key is read after the refresh: reading the stored key is
        // what fills the channel's in-memory copy on a fresh launch.
        .task(id: isUnlocked) {
            await environment.refreshEntitlement()
            maskedKey = await environment.entitlements.maskedLicenseKey()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purchase.view")
    }

    /// Locked, the page sells; unlocked, it reports what was bought.
    private var pageTitle: String {
        isUnlocked
            ? LocalizationKey.navAccount.localized
            : LocalizationKey.purchaseTitle.localized
    }

    private var headerStatus: String {
        isUnlocked
            ? LocalizationKey.purchaseActivated.localized
            : LocalizationKey.purchaseLicenseRequired.localized
    }

    /// The verified-at timestamp, whichever unlocked status is in force.
    private var activatedAt: Date? {
        switch environment.entitlement.status {
        case let .unlocked(verifiedAt), let .offlineGrace(verifiedAt, _): verifiedAt
        case .free: nil
        }
    }

    // MARK: - Account (unlocked)

    /// The account panel: the plan, the activation date and the stored key with
    /// only its ends showing, plus the two actions a direct licence has.
    ///
    /// The free/paid comparison is paywall material — an unlocked user has
    /// already decided — so it stays on the locked page only.
    private var accountSection: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Label {
                    Text(LocalizationKey.navAccount.localized)
                        .font(SiftFont.sectionTitle)
                } icon: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(SiftColor.accent)
                }
                Text(LocalizationKey.purchasePriceLine.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if let activatedAt {
                    accountRow(
                        LocalizationKey.accountActivatedAt.localized,
                        SiftFormat.timestamp(activatedAt)
                    )
                }
                if let maskedKey {
                    accountRow(
                        LocalizationKey.accountLicenseKey.localized,
                        maskedKey
                    )
                }
                if let days = environment.entitlement.status.graceDaysRemaining {
                    Text(LocalizationKey.purchaseOfflineGrace.localized(days))
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.review)
                }

                Divider()

                HStack(spacing: SiftMetrics.spacingM) {
                    SiftSecondaryButton(titleKey: .purchaseRestore) {
                        Task { await restore() }
                    }
                    .disabled(isWorking)

                    // The remove action exists where a key exists; it is how a
                    // stored key leaves the machine short of the terminal.
                    if maskedKey != nil {
                        Button {
                            Task { await removeStoredLicense() }
                        } label: {
                            Text(LocalizationKey.settingsRemoveLicense.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                        .disabled(isWorking)
                    }

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private func accountRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(SiftFont.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: SiftMetrics.spacingM)
            Text(value)
                .font(SiftFont.bodyEmphasis)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var comparison: some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
            TierCard(
                titleKey: .purchaseStatusFree,
                symbolName: "checkmark.seal",
                tint: SiftColor.safe,
                items: [
                    .purchaseFreeTierScan,
                    .purchaseFreeTierExplain,
                    .purchaseFreeTierEstimate,
                    .purchaseFreeTierStorage,
                ]
            )
            TierCard(
                titleKey: .purchasePaidTierTitle,
                symbolName: "lock.open",
                tint: SiftColor.accent,
                items: [
                    .purchasePaidTierClean,
                    .purchasePaidTierUninstall,
                    .purchasePaidTierFiles,
                    .purchasePaidTierReport,
                ]
            )
        }
    }

    private var licenseSection: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.purchaseActivateLicense.localized)
                    .font(SiftFont.sectionTitle)
                TextField(LocalizationKey.purchaseActivateLicense.localized, text: $licenseKey)
                    .textFieldStyle(.plain)
                    .font(SiftFont.body)
                    .padding(.horizontal, SiftMetrics.spacingM)
                    .frame(maxWidth: 320)
                    .frame(height: SiftMetrics.fieldHeight)
                    .siftFieldSurface()
                HStack(spacing: SiftMetrics.spacingM) {
                    SiftPrimaryButton(
                        title: LocalizationKey.purchaseBuyButton.localized(environment.entitlement.formattedPrice),
                        isEnabled: !isWorking && !licenseKey.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        Task { await activate() }
                    }

                    SiftSecondaryButton(titleKey: .purchaseRestore) {
                        Task { await restore() }
                    }
                    .disabled(isWorking)

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(LocalizationKey.purchaseLicenseRequiredDetail.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.settingsPrivacyStatement.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activate() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await environment.entitlements.activate(licenseKey: licenseKey)
            await environment.refreshEntitlement()
            message = (false, LocalizationKey.purchaseActivated.localized)
        } catch let error as PurchaseError {
            message = (true, error.message)
        } catch {
            message = (true, LocalizationKey.purchaseFailed.localized)
        }
    }

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await environment.entitlements.restore()
            await environment.refreshEntitlement()
            maskedKey = await environment.entitlements.maskedLicenseKey()
            message = (false, LocalizationKey.purchaseRestored.localized)
        } catch let error as PurchaseError {
            message = (true, error.message)
        } catch {
            message = (true, LocalizationKey.purchaseFailed.localized)
        }
    }

    private func removeStoredLicense() async {
        isWorking = true
        defer { isWorking = false }
        _ = await environment.removeStoredLicense()
        maskedKey = nil
        // No banner: the page itself flips to the locked layout, which is the
        // answer the user can see.
    }
}

/// One column of the free/paid comparison.
struct TierCard: View {
    let titleKey: LocalizationKey
    let symbolName: String
    let tint: Color
    let items: [LocalizationKey]

    var body: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Label {
                    Text(titleKey.localized)
                        .font(SiftFont.sectionTitle)
                } icon: {
                    Image(systemName: symbolName)
                        .foregroundStyle(tint)
                }
                ForEach(items, id: \.rawValue) { item in
                    HStack(alignment: .top, spacing: SiftMetrics.spacingS) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                        Text(item.localized)
                            .font(SiftFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
