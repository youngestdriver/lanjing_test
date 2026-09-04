import SwiftUI

/// 练习答题卡 overlay: jump-to-any-question dot grid. Mirrors the exam
/// AnswerCardSheet's look but has no sections and no submission — practice
/// has neither. Tapping a dot calls `vm.jumpTo`; like the exam, the card
/// stays open and is dismissed by 完成 or the dim mask. The target question's
/// per-question state lives in `session.answers`, so nothing is lost when
/// jumping (问题 5).
///
/// Presented as an overlay, NOT a `.sheet`: presenting a sheet from a view
/// whose tab bar is hidden (`.toolbar(.hidden, for: .tabBar)`) silently does
/// nothing on iOS 17 (known bug, no official fix), and the tab bar must stay
/// hidden for the full-screen 问题 4 contract.
struct PracticeAnswerCardView: View {
    let vm: PracticeBankViewModel
    let onClose: () -> Void

    private var session: PracticeSession? { vm.session }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                header
                if let session {
                    grid(session)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 480)
            .background(Color(.systemBackground))
            // 面板形态与考试答题卡对齐:全宽贴底、仅顶部圆角(DS.radiusLG)。
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: DS.radiusLG,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: DS.radiusLG
            ))
        }
        // NOTE: no accessibilityIdentifier on this ZStack — SwiftUI propagates
        // a container's identifier to EVERY descendant, overwriting the grid's
        // own "practice-answer-card-grid" (UI tests scope on that ScrollView).
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 标题栏模拟考试 sheet 的导航栏:居中标题 + 右侧「完成」。完成按钮带
    /// 独立 identifier — 遮罩下层的题目页还有自己的「完成/下一题」按钮,
    /// 按标签查询会歧义。
    private var header: some View {
        ZStack {
            Text("答题卡")
                .font(.system(size: 17, weight: .heavy))
            HStack {
                Spacer()
                Button("完成") { onClose() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.blue)
                    .accessibilityIdentifier("practice-answer-card-close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                .padding(16)
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
        // 与考试一致:跳转后卡片保持打开,由「完成」或遮罩关闭。
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
