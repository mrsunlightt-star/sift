import Shared
import SwiftUI

/// The state a feature shows before a scan has run.
public struct ScanGateCard: View {
    public let titleKey: LocalizationKey
    public let detailKey: LocalizationKey
    public let onStart: () -> Void

    public init(titleKey: LocalizationKey, detailKey: LocalizationKey, onStart: @escaping () -> Void) {
        self.titleKey = titleKey
        self.detailKey = detailKey
        self.onStart = onStart
    }

    public var body: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(titleKey.localized)
                    .font(SiftFont.title)
                Text(detailKey.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryActionButton(titleKey: .dashboardStartScan, symbolName: "viewfinder") {
                    onStart()
                }
            }
        }
    }
}

