import Core
import Shared
import SwiftUI

/// The purchase page (§12).
///
/// Two things this page must get right, both stated in the specification: the
/// price line is exactly "$4.99 once, yours forever, no subscription", and the
/// free tier is described honestly — what it already does — rather than being
/// framed as a limitation.
///
/// The layout is one hero, one list of rows, one primary action. The hero states
/// the offer, the rows state what each tier does, and the page never claims a
/// purchase happened: with no licence service in the build, the most it can say
/// is that the store link is unavailable and that a stored key can be removed.
public struct PurchaseView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let reason: PaywallReasonLink?
    @State private var licenseKey = ""
    @State private var isWorking = false
    @State private var maskedKey: String?
    @State private var message: (isError: Bool, text: String)?
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(reason: PaywallReasonLink? = nil) {
        self.reason = reason
    }

    private var isUnlocked: Bool { environment.entitlement.isUnlocked }

    private var canActivate: Bool {
        !isWorking && !licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            SiftPageHeader(title: pageTitle, status: headerStatus) {
                SiftMetricPill(
                    symbolName: isUnlocked ? "checkmark.seal.fill" : "lock.open",
                    value: (isUnlocked
                        ? LocalizationKey.purchaseStatusPurchased
                        : LocalizationKey.purchaseStatusFree).localized,
                    tone: isUnlocked ? .safe : .accent
                )
            }

            SiftPage(maxWidth: SiftMetrics.contentWidthForm) {
                if isUnlocked {
                    accountSection
                } else {
                    salesHero

                    // The reason the paywall opened is its own sentence.
                    // Concatenating it with the free-tier sentence produced "Scan,
                    // scanning and previews stay free" — the page name used as a
                    // clause.
                    if reason != nil {
                        NoticeBanner(
                            level: .information,
                            message: LocalizationKey.purchaseLicenseRequiredDetail.localized
                        )
                    }

                    comparison
                }

                if let message {
                    NoticeBanner(
                        level: message.isError ? .warning : .success,
                        message: message.text
                    )
                }

                Text(LocalizationKey.settingsPrivacyStatement.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The masked key is read after the refresh: reading the stored key is
        // what fills the channel's in-memory copy on a fresh launch.
        .task(id: isUnlocked) {
            await environment.refreshEntitlement()
            maskedKey = await environment.entitlements.maskedLicenseKey()
        }
        // Locked and unlocked are two layouts, not one with parts hidden: the
        // swap is a fade long enough to read as a change of state and short
        // enough not to make the page wait.
        .animation(
            SiftMotion.respectingReduceMotion(SiftMotion.quick, reduceMotion: reduceMotion),
            value: isUnlocked
        )
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

    // MARK: - Locked

    /// The offer, and the one action that changes it.
    ///
    /// The key field lives inside the hero rather than in a panel of its own: a
    /// second boxed block under a boxed block is two offers on one page, and the
    /// button that reads the field has to sit beside it or the page asks the user
    /// to type in one place and act in another.
    private var salesHero: some View {
        // `actionFill` is a fill-role token here: it tints the hero's wash and its
        // glyph, never the title. The page's text stays `mainText`/`secondaryText`,
        // so the offer reads at full contrast in both appearances.
        SiftHeroCard(
            symbolName: "lock.open",
            title: LocalizationKey.purchasePriceLine.localized,
            detail: LocalizationKey.purchaseUpdatesPromise.localized,
            tint: SiftColor.actionFill
        ) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(spacing: SiftMetrics.spacingS) {
                    TextField(LocalizationKey.purchaseActivateLicense.localized, text: $licenseKey)
                        .textFieldStyle(.plain)
                        .font(SiftFont.body)
                        .padding(.horizontal, SiftMetrics.spacingM)
                        .frame(maxWidth: 320)
                        .frame(height: SiftMetrics.fieldHeight)
                        .siftFieldSurface()
                        .accessibilityLabel(Text(LocalizationKey.purchaseActivateLicense.localized))

                    SiftPrimaryButton(
                        title: LocalizationKey.purchaseActivate.localized,
                        isEnabled: canActivate
                    ) {
                        Task { await activate() }
                    }
                    .accessibilityIdentifier("purchase.activate")

                    SiftSecondaryButton(titleKey: .purchaseRestore) {
                        Task { await restore() }
                    }
                    .disabled(isWorking)

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }

                // The purchase happens on the website, so this is a link with an
                // address — not a button that pretends to charge a card it never
                // sees. With no store URL configured the row says why instead of
                // opening something that cannot work: a release build has no
                // licence service behind it, and the page must not imply one.
                if let storeURL = Self.storeURL {
                    Button {
                        NSWorkspace.shared.open(storeURL)
                    } label: {
                        Text(LocalizationKey.purchaseOpenStore.localized)
                            .font(SiftFont.supporting)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                    .accessibilityIdentifier("purchase.openStore")
                } else {
                    Text(LocalizationKey.purchaseUnavailable.localized)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What each tier does, as rows.
    ///
    /// The two items were cards side by side, which presented a statement of fact
    /// ("this is what the free tier does") and a list of features as two competing
    /// products. As rows they read as one table: the boundary sentence first, then
    /// what stays free, then what unlocking adds.
    private var comparison: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizationKey.purchaseLicenseRequiredDetail.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, SiftMetrics.spacingM)

                tierRows(
                    titleKey: .purchaseStatusFree,
                    symbolName: "checkmark.circle",
                    glyph: SiftColor.safeTextColor,
                    items: [
                        .purchaseFreeTierScan,
                        .purchaseFreeTierExplain,
                        .purchaseFreeTierEstimate,
                        .purchaseFreeTierStorage,
                    ]
                )

                SiftHairline()
                    .padding(.vertical, SiftMetrics.spacingM)

                tierRows(
                    titleKey: .purchasePaidTierTitle,
                    symbolName: "lock.open",
                    glyph: SiftColor.actionGreen,
                    items: [
                        .purchasePaidTierClean,
                        .purchasePaidTierUninstall,
                        .purchasePaidTierFiles,
                        .purchasePaidTierReport,
                    ]
                )
            }
        }
    }

    /// One tier: a heading and four rows, each marked with a glyph and a word-free
    /// tick, because the glyph repeats what the heading already says.
    private func tierRows(
        titleKey: LocalizationKey,
        symbolName: String,
        glyph: Color,
        items: [LocalizationKey]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(glyph)
                    .accessibilityHidden(true)
                Text(titleKey.localized)
                    .font(SiftFont.secondaryHeading)
                    .foregroundStyle(SiftColor.mainText)
            }
            .padding(.bottom, SiftMetrics.spacingXS)

            ForEach(items, id: \.rawValue) { item in
                HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingS) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(glyph)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                    Text(item.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 26)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Account (unlocked)

    /// The account, in the same shape as the offer: a hero that states the plan,
    /// then rows for the two facts and the two actions a direct licence has.
    ///
    /// The free/paid comparison is paywall material — an unlocked user has already
    /// decided — so it stays on the locked page only.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
            SiftHeroCard(
                symbolName: "checkmark.seal.fill",
                title: LocalizationKey.purchaseStatusPurchased.localized,
                detail: LocalizationKey.purchasePriceLine.localized,
                tint: SiftColor.actionFill
            ) {
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
                                .font(SiftFont.supporting)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                        .disabled(isWorking)
                    }

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            SiftSection {
                VStack(alignment: .leading, spacing: 0) {
                    if let activatedAt {
                        accountRow(
                            LocalizationKey.accountActivatedAt.localized,
                            SiftFormat.timestamp(activatedAt)
                        )
                    }
                    if let maskedKey {
                        if activatedAt != nil {
                            SiftHairline()
                        }
                        accountRow(
                            LocalizationKey.accountLicenseKey.localized,
                            maskedKey
                        )
                    }
                    if let days = environment.entitlement.status.graceDaysRemaining {
                        if activatedAt != nil || maskedKey != nil {
                            SiftHairline()
                        }
                        Text(LocalizationKey.purchaseOfflineGrace.localized(days))
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.reviewTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, SiftMetrics.spacingS)
                    }
                }
            }
        }
    }

    private func accountRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.secondaryText)
            Spacer(minLength: SiftMetrics.spacingM)
            Text(value)
                .font(SiftFont.monospacedEmphasis)
                .foregroundStyle(SiftColor.mainText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(minHeight: SiftMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }

    /// The hosted checkout page, from `Info.plist`.
    ///
    /// The spec keeps the store address out of the binary's control flow: the
    /// page is a licence-service decision, and a build without one must be able
    /// to say "not available" rather than open a dead link.
    static var storeURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SiftStoreURL") as? String,
              let url = URL(string: raw), url.scheme == "https"
        else { return nil }
        return url
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
