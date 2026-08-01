import SwiftUI

struct ExamCardView: View {
    @Environment(AppState.self) private var appState
    let vm: ExamListViewModel
    let exam: Exam
    @State private var confirmAbandon = false

    var body: some View {
        Button {
            appState.route = .quiz(exam)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(DS.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
                VStack(alignment: .leading, spacing: 6) {
                    Text(exam.name)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        badge(exam.isNew ? "新试卷" : "继续考试",
                              color: exam.isNew ? DS.blue : DS.accent)
                        badge(exam.modeLabel, color: DS.pink)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(exam.timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("放弃", role: .destructive) {
                confirmAbandon = true
            }
        }
        .confirmationDialog("确定放弃「\(exam.name)」吗？放弃后本次作答将直接交卷。",
                            isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("确认放弃", role: .destructive) {
                Task { await vm.abandon(exam) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
