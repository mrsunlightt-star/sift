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
    @State private var message: (isError: Bool, text: String)?

    public init(reason: PaywallReasonLink? = nil) {
        self.reason = reason
    }

    public var body: some View {
        SiftPage(maxWidth: SiftMetrics.contentWidthForm) {
            PageHeader(titleKey: .purchaseTitle) {
                if environment.entitlement.isUnlocked {
                    SiftMetricPill(
                        symbolName: "checkmark.seal.fill",
                        value: LocalizationKey.purchaseStatusPurchased.localized,
                        tint: SiftColor.safe
                    )
                }
            }

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
                    message: "\(reason.titleKey.localized) · \(LocalizationKey.purchaseLicenseRequiredDetail.localized)"
                )
            }

            comparison
            if !environment.entitlement.isUnlocked {
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
        .task {
            await environment.refreshEntitlement()
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
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                HStack(spacing: SiftMetrics.spacingM) {
                    Button {
                        Task { await activate() }
                    } label: {
                        Text(LocalizationKey.purchaseBuyButton.localized(environment.entitlement.formattedPrice))
                            .font(SiftFont.bodyEmphasis)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        Task { await restore() }
                    } label: {
                        Text(LocalizationKey.purchaseRestore.localized)
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
            message = (false, LocalizationKey.purchaseRestored.localized)
        } catch let error as PurchaseError {
            message = (true, error.message)
        } catch {
            message = (true, LocalizationKey.purchaseFailed.localized)
        }
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
