import SwiftUI

/// 练习答题卡 overlay: stats row + jump-to-any-question dot grid. Mirrors
/// the exam AnswerCardSheet's look but has no sections and no submission —
/// practice has neither. Tapping a dot calls `vm.jumpTo` and closes the
/// card; the target question's per-question state lives in `session.answers`,
/// so nothing is lost when jumping (问题 5).
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
                    statsBar(session)
                    grid(session)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 420)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("practice-answer-card")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack {
            Text("答题卡")
                .font(.system(size: 16, weight: .heavy))
            Spacer()
            Button("完成") { onClose() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 答对 / 答错 / 未答 counters — derived from session.answers, so the
    /// card statistics never drift from the summary.
    private func statsBar(_ session: PracticeSession) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Label("\(session.rightCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DS.accent)
                Label("\(session.wrongCount)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(DS.red)
                Label("\(session.questions.count - session.answeredCount)", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
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
        }
    }

    private func dot(_ session: PracticeSession, _ index: Int) -> some View {
        let answer = index < session.answers.count
            ? session.answers[index]
            : PracticeSession.PracticeAnswer()
        let isCurrent = index == session.index
        return Button {
            vm.jumpTo(index)
            onClose()
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
