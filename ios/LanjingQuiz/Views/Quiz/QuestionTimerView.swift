import SwiftUI

/// Per-question 60s countdown pill: orange active / gray paused / red expired.
struct QuestionTimerView: View {
    let vm: QuizViewModel

    var body: some View {
        HStack(spacing: 4) {
            Text("⏱")
            Text(Formatters.mmss(vm.displayedSeconds))
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background)
        .clipShape(Capsule())
    }

    private var foreground: Color {
        switch vm.timerMode {
        case .active: DS.orange
        case .paused: .secondary
        case .expired: DS.red
        }
    }

    private var background: Color {
        switch vm.timerMode {
        case .active: DS.orange.opacity(0.15)
        case .paused: Color(.systemGray5)
        case .expired: DS.red.opacity(0.15)
        }
    }
}
