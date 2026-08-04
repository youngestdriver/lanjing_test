import SwiftUI

/// 16pt green pill progress bar with the web's bounce easing (index.html:729-753).
struct ProgressBarView: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray5))
                Capsule()
                    .fill(DS.accent)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: progress)
    }
}
