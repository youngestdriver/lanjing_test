import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            switch appState.route {
            case .login:
                LoginView()
            case .examList:
                ExamListView()
            case .quiz(let exam):
                QuizView(exam: exam)
            case .result(let result):
                ResultView(result: result)
            }
        }
        .overlay(alignment: .top) {
            if let notice = appState.notice {
                HStack(spacing: 12) {
                    Text(notice)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        appState.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DS.orange)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
                .padding(.horizontal)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.notice)
        .task { await appState.start() }
    }
}
