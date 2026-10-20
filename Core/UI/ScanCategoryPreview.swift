import Shared
import SwiftUI

/// The categories a scan will look for, shown before it starts.
///
/// It answers "what will this scan touch?" next to the button that starts it,
/// using the same names and colours the result groups use, so the first-run page
/// is informative rather than an empty card in a large window.
public struct ScanCategoryPreview: View {
    private let categories: [CleanupCategory]

    public init(_ categories: [CleanupCategory]) {
        self.categories = categories
    }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: SiftMetrics.spacingM)],
            alignment: .leading,
            spacing: SiftMetrics.spacingM
        ) {
            ForEach(categories) { category in
                HStack(spacing: SiftMetrics.spacingM) {
                    IconTile(
                        symbolName: category.symbolName,
                        tint: SiftColor.categoryPalette[category.paletteIndex]
                    )
                    Text(category.titleKey.localized)
                        .font(SiftFont.bodyEmphasis)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(SiftMetrics.spacingM)
                .background(
                    SiftColor.panel,
                    in: RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                        .stroke(SiftColor.border.opacity(0.7), lineWidth: SiftMetrics.panelBorderWidth)
                }
            }
        }
    }
}
