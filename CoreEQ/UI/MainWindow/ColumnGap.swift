import SwiftUI

/// The space between two columns, in the title row and in every band row — one
/// definition, because a gap that differed between them would put every title
/// off its column by the difference, multiplied along the row.
///
/// Flexible rather than fixed: the columns are sized for their controls, so a
/// window wider than the minimum has width left over, and sharing it between
/// the gaps is what keeps the table from sitting bunched against its left edge.
struct ColumnGap: View {
    var body: some View {
        Spacer(minLength: Theme.FilterRow.columnSpacing)
            .frame(maxWidth: Theme.FilterRow.columnSpacingMax)
    }
}
