import SwiftUI

/// Practice quiz screen: header, stem, option rows, multi-select confirm,
/// answer-reveal banner (with remote formula images), next/finish. Pushed
/// inside the tab's NavigationStack, the page hides the tab bar (问题 4 —
/// full screen). Question changes rebuild the content web views via
/// `.id(question.id)` while the scroll snaps back to the top (问题 1).
struct PracticeQuizView: View {
    let vm: PracticeBankViewModel
    let category: String
    let subCategory: String

    @Environment(\.dismiss) private var dismiss
    @State private var showAnswerCard = false

    private var session: PracticeSession? { vm.session }
    private var question: BankQuestion? { vm.currentQuestion }

    var body: some View {
        Group {
            if let session, !session.questions.isEmpty {
                if session.isFinished {
                    summaryCard(session)
                } else if let question {
                    quizContent(session, question)
                }
            } else if vm.phase != .ready {
                // Bank became unavailable mid-session — the bank view's phase
                // switch shows the failure screen instead.
                EmptyView()
            } else {
                loadingPlaceholder
            }
        }
        .navigationTitle("\(vm.session?.subCategory ?? subCategory)")
        .navigationBarTitleDisplayMode(.inline)
        // 问题 4: the quiz page is pushed within the tab's NavigationStack —
        // hide the tab bar so practice (and its summary) is full screen; the
        // tab bar returns automatically when popped back. Presenting the
        // answer-card sheet while the tab bar is hidden fails to present on
        // iOS 17 (presentation coordinator vs hidden tab bar), so the tab bar
        // is made visible while the sheet is up (invisible behind the sheet).
        .toolbar(showAnswerCard ? .visible : .hidden, for: .tabBar)
        .task {
            // Resume a persisted run of this subcategory when it matches the
            // current bank (question-ID order check), otherwise start fresh.
            // System-back / swipe-back no longer clears anything — exiting
            // mid-run and re-entering continues where it left off (问题 3).
            await vm.resumeOrStart(category: category, subCategory: subCategory)
        }
        .toolbar {
            if !(vm.session?.isFinished ?? true) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("答题卡") { showAnswerCard = true }
                }
            }
        }
        .sheet(isPresented: $showAnswerCard) {
            PracticeAnswerCardView(vm: vm)
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载题目…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func quizContent(_ session: PracticeSession, _ question: BankQuestion) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Scroll-to-top anchor for question changes (包括答题卡跳题).
                    Color.clear
                        .frame(height: 0)
                        .id("quiz-top")
                    headerRow(session, question)
                    if vm.resumedFromDisk && !session.isFinished {
                        resumeBanner
                    }
                    // Comb (资料分析) material stem, rendered above the sub-question.
                    if let stem = question.stem, !stem.isEmpty {
                        RichHTMLContent(html: stem, fontSize: 15)
                            // 问题 1: keying the identity per question rebuilds
                            // the WKWebView and resets its reported height, so a
                            // long → short question never keeps the old height.
                            .id(question.id)
                            .padding(.bottom, 4)
                            .overlay(alignment: .bottom) {
                                Divider()
                            }
                    }
                    RichHTMLContent(html: question.question, fontSize: 17)
                        .id(question.id)
                    options(for: session, question)
                    if let answer = session.currentAnswer, answer.revealed {
                        ExplainBannerView(
                            correct: answer.correct,
                            answerLabel: question.correctAnswers.joined(separator: "、"),
                            analysis: question.analysis
                        )
                        Button(session.isLast ? "完成" : "下一题") {
                            vm.nextQuestion()
                        }
                        .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: question.id) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("quiz-top", anchor: .top)
                }
            }
        }
    }

    /// One-off notice that a persisted run was resumed (问题 3 的交互提示).
    /// consumeResumeNotice() dismisses it; the flag resets on every entry.
    private var resumeBanner: some View {
        HStack(spacing: 12) {
            Label("已恢复上次练习进度", systemImage: "arrow.counterclockwise")
            Spacer(minLength: 0)
            Button("知道了") { vm.consumeResumeNotice() }
                .font(.system(size: 13, weight: .bold))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.blue)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.blue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
    }

    private func headerRow(_ session: PracticeSession, _ question: BankQuestion) -> some View {
        HStack(spacing: 8) {
            Text("第 \(session.index + 1)/\(session.questions.count) 题")
                .font(.system(size: 13, weight: .heavy))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            if question.isMulti {
                Text("多选")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
            if !question.isGradable {
                Text("无答案")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
            Text("答对 \(session.rightCount) · 答错 \(session.wrongCount)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func options(for session: PracticeSession, _ question: BankQuestion) -> some View {
        // currentAnswer is bounds-guarded; answers is index-aligned with
        // questions (构造/解码双重保证), and !isFinished guarantees index < count.
        let answer = session.currentAnswer ?? PracticeSession.PracticeAnswer()
        VStack(spacing: 12) {
            ForEach(question.letters, id: \.self) { letter in
                PracticeOptionRowView(
                    question: question,
                    letter: letter,
                    answer: answer,
                    onTap: { vm.tapOption(letter) }
                )
            }
        }
        if question.isMulti, !answer.revealed, !answer.selected.isEmpty {
            Button("提交") {
                vm.confirmSelection()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
            .padding(.top, 4)
        }
    }

    private func summaryCard(_ session: PracticeSession) -> some View {
        VStack(spacing: 16) {
            Image(systemName: session.wrongCount == 0 ? "checkmark.seal.fill" : "flag.checkered")
                .font(.system(size: 44))
                .foregroundStyle(session.wrongCount == 0 ? DS.accent : DS.orange)
            Text("练习完成")
                .font(.system(size: 20, weight: .heavy))
            VStack(spacing: 6) {
                Text("答对 \(session.rightCount) 题")
                Text("答错 \(session.wrongCount) 题")
                Text("共 \(session.questions.count) 题")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15))
            Button("返回题型列表") {
                vm.endSession()
                dismiss()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension PracticeSession {
    var isLast: Bool { index + 1 >= questions.count }
}
