import SwiftUI

/// 练习答题卡 sheet: jump-to-any-question dot grid. 与考试 AnswerCardSheet
/// 完全同构(NavigationStack + inline 标题 + 右上「完成」+ .medium/.large
/// detents);练习无 section(镜像考试单 section 时 SectionTabsView 不渲染)、
/// 无交卷。点圆点只跳转、卡片保持打开,由「完成」/下滑关闭 —— 与考试一致;
/// 每题状态在 session.answers,跳转不丢(问题 5)。
///
/// 呈现历史:练习页需隐藏 tab bar(iOS 17 下从该层级 present sheet 是已知
/// bug,sheet 静默不出现)曾改为 overlay(commit 6c42862)。现按产品要求
/// 复刻考试的 sheet 呈现,在 iOS 26/27 上实测可用;若 iOS 17 设备复现失败,
/// 回退方案是把 sheet 挂到更外层呈现容器(RootView 层),而不是回到 overlay。
struct PracticeAnswerCardView: View {
    let vm: PracticeBankViewModel
    @Environment(\.dismiss) private var dismiss

    private var session: PracticeSession? { vm.session }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    grid(session)
                } else {
                    Spacer()
                }
            }
            .navigationTitle("答题卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 独立 identifier —— 遮罩下层的题目页还有自己的
                    // 「完成/下一题」按钮,按标签查询会歧义(与测试对齐)。
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("practice-answer-card-close")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func grid(_ session: PracticeSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 10) {
                    ForEach(session.questions.indices, id: \.self) { index in
                        dot(session, index)
                            .id(index)
                    }
                }
                .padding()
            }
            .onChange(of: vm.session?.index) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .accessibilityIdentifier("practice-answer-card-grid")
        }
    }

    private func dot(_ session: PracticeSession, _ index: Int) -> some View {
        let answer = index < session.answers.count
            ? session.answers[index]
            : PracticeSession.PracticeAnswer()
        let isCurrent = index == session.index
        // 与考试一致:跳转后卡片保持打开,由「完成」或下滑关闭。
        return Button {
            vm.jumpTo(index)
        } label: {
            // Accessible label is the 1-based number ("1".."n") — UI tests
            // can scope card.buttons["3"] without colliding with letters.
            Text("\(index + 1)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(foreground(for: answer, isCurrent: isCurrent))
                .frame(width: 36, height: 36)
                .background(fill(for: answer))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(border(for: answer, isCurrent: isCurrent),
                                lineWidth: isCurrent ? 3 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func fill(for answer: PracticeSession.PracticeAnswer) -> Color {
        if answer.correct == true { return DS.accent }
        if answer.correct == false { return DS.red }
        // 未答 or 无答案已答 — the border distinguishes them.
        return Color(.systemGray5)
    }

    private func border(for answer: PracticeSession.PracticeAnswer, isCurrent: Bool) -> Color {
        if isCurrent { return DS.blue } // current wins, highest priority
        if answer.correct == true { return DS.accent }
        if answer.correct == false { return DS.red }
        if answer.revealed { return DS.orange } // 无答案已答
        return Color(.systemGray4)
    }

    private func foreground(for answer: PracticeSession.PracticeAnswer, isCurrent: Bool) -> Color {
        if answer.correct != nil { return .white }
        return isCurrent ? DS.blue : .secondary
    }
}
