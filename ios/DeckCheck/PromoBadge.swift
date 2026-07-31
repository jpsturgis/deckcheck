import SwiftUI

/// Marks a hand-entered promo that's showing its *linked* card's image (#50): the art
/// is the equivalent printing's, so the star badge flags "this is the promo version."
struct PromoBadge: View {
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .padding(4)
                    .background(.black.opacity(0.7), in: Circle())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                    Text("PROMO")
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.black.opacity(0.7), in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }
}
