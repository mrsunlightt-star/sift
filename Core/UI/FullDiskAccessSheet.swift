import Shared
import SwiftUI

/// Why Sift wants Full Disk Access, in the app rather than in a system dialog.
///
/// macOS's own prompt cannot be edited, so the explanation has to happen before
/// it: what the permission unlocks, why the product wants it, and — the part
/// that makes the ask reasonable — that every other feature works without it and
/// the switch can be turned off again. The two buttons are the two answers the
/// user actually has: go and grant it, or carry on as they were.
public struct FullDiskAccessSheet: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    public init(onOpenSettings: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            HStack(spacing: SiftMetrics.spacingM) {
                IconTile(symbolName: "lock.shield", tint: SiftColor.accentText)
                Text(LocalizationKey.permissionAskTitle.localized)
                    .font(SiftFont.title)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                row(
                    symbolName: "doc.text.magnifyingglass",
                    title: LocalizationKey.permissionWhyTitle.localized,
                    detail: LocalizationKey.permissionWhyBody.localized
                )
                row(
                    symbolName: "arrow.uturn.backward.circle",
                    title: LocalizationKey.permissionFullDiskAccess.localized,
                    detail: LocalizationKey.permissionWhyRevoke.localized
                )
            }

            Divider()

            HStack(spacing: SiftMetrics.spacingM) {
                Spacer()
                SiftSecondaryButton(titleKey: .permissionGrantLater) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                SiftPrimaryButton(titleKey: .permissionOpenSettings) {
                    onOpenSettings()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("permission.openSettings")
            }
        }
        .padding(SiftMetrics.spacingXL)
        .frame(width: 480)
    }

    private func row(symbolName: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SiftColor.accentText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SiftFont.bodyEmphasis)
                Text(detail)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
