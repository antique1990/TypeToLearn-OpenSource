import SwiftUI

/// The mark stays decorative beside the localized, accessible product name.
struct BrandTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .headline) private var logoSize = 28.0

    var body: some View {
        HStack(spacing: 8) {
            Image("TypeToLearnLogo")
                .resizable()
                .scaledToFit()
                .frame(width: min(logoSize, 36), height: min(logoSize, 36))
                .clipShape(RoundedRectangle(cornerRadius: min(logoSize, 36) / 4, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("home.brand")
    }
}
