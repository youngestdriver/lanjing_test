import SwiftUI

struct QuizHeaderView: View {
    let vm: QuizViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    vm.cancel()
                    appState.route = .examList
                } label: {
                    Text("✕")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(vm.exam.name)
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(1)
                Spacer()
                QuestionTimerView(vm: vm)
                Button(appState.theme.toggleLabel) {
                    appState.toggleTheme()
                }
                .font(.system(size: 16))
            }
            ProgressBarView(progress: vm.progress)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}
