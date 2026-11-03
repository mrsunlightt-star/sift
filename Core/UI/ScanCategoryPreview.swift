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
        // No surface per category. The first version wrapped each name in a
        // material card with a border, which turned a five-word answer into a
        // grid of outlined boxes — the pattern V2 §4 rules out for page content
        // ("a page should not become a grid of outlined cards just because a
        // reusable card component exists"). A tinted glyph and the name carry the
        // same information without asking to be read as five separate things.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: SiftMetrics.spacingXL)],
            alignment: .leading,
            spacing: SiftMetrics.spacingM
        ) {
            ForEach(categories) { category in
                HStack(spacing: SiftMetrics.spacingS) {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SiftColor.categoryPalette[category.paletteIndex])
                        .frame(width: 20, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(category.titleKey.localized)
                        .font(SiftFont.secondaryHeading)
                        .foregroundStyle(SiftColor.mainText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: SiftMetrics.rowHeight - SiftMetrics.spacingM)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
