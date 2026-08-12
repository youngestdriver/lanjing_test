import SwiftUI

/// 练习答题页底部统计栏:镜像考试 StatsBarView 的设计(答对/答错/未答 +
/// 答题卡胶囊),但练习没有交卷 —— 无提交按钮与确认对话框(需求 1)。
struct PracticeStatsBarView: View {
    let vm: PracticeBankViewModel
    let onOpenAnswerCard: () -> Void

    private var session: PracticeSession? { vm.session }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Label("\(session?.rightCount ?? 0)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DS.accent)
                Label("\(session?.wrongCount ?? 0)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(DS.red)
                Label("\((session?.questions.count ?? 0) - (session?.answeredCount ?? 0))", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .bold))
            Spacer()
            Button {
                onOpenAnswerCard()
            } label: {
                Text("答题卡")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
