import SwiftUI

/// Practice quiz screen: header, stem, option rows, multi-select confirm,
/// answer-reveal banner (with remote formula images), next/finish. Pushed
/// inside the tab's NavigationStack, the page hides the tab bar (问题 4 —
/// full screen). Questions page left/right like the exam (需求 2): a
/// TabView(.page) whose selection binds to vm.jumpTo; each page is its own
/// ScrollView and reads that page index's answer (per-page rebuilds of the
/// web content are keyed via `.id(question.id)`).
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
        // tab bar returns automatically when popped back.
        .toolbar(.hidden, for: .tabBar)
        .task {
            // Resume a persisted run of this subcategory when it matches the
            // current bank (question-ID set check), otherwise start fresh.
            // System-back / swipe-back no longer clears anything — exiting
            // mid-run and re-entering continues where it left off (问题 3).
            await vm.resumeOrStart(category: category, subCategory: subCategory)
        }
        // 答题卡 is an overlay, NOT a sheet: presenting a sheet from a view
        // with a hidden tab bar silently fails on iOS 17 (known bug), so the
        // card overlays the full-screen page instead.
        .overlay {
            if showAnswerCard {
                PracticeAnswerCardView(vm: vm, onClose: { showAnswerCard = false })
                    .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showAnswerCard)
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
        VStack(spacing: 0) {
            headerRow(session, question)
                .padding(.horizontal)
                .padding(.top, 8)
            if vm.resumedFromDisk && !session.isFinished {
                resumeBanner
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            TabView(selection: pageSelection) {
                ForEach(Array(session.questions.enumerated()), id: \.offset) { index, q in
                    questionPage(session, index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)
            // Bottom bar mirrors the exam's AnswerCardView container (stats +
            // 答题卡, no 交卷 — 需求 1).
            PracticeStatsBarView(vm: vm) { showAnswerCard = true }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
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

    /// 滑动/答题卡跳转共用:TabView selection 绑定走 vm.jumpTo(越界与同
    /// 索引为 no-op;索引已持久化,滑动位置重启后保留)。
    private var pageSelection: Binding<Int> {
        Binding(
            get: { vm.session?.index ?? 0 },
            set: { vm.jumpTo($0) }
        )
    }

    /// 单页 = 一个可滚动题目页。页内答案取本页索引,而不是全局
    /// currentAnswer(相邻页渲染时全局 index 指向当前页,会错位)。
    private func questionPage(_ session: PracticeSession, _ index: Int) -> some View {
        let question = session.questions[index]
        let answer = index < session.answers.count
            ? session.answers[index]
            : PracticeSession.PracticeAnswer()
        let isLast = index + 1 >= session.questions.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stem = question.stem, !stem.isEmpty {
                    RichHTMLContent(html: stem, fontSize: 15)
                        .id(question.id)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) { Divider() }
                }
                RichHTMLContent(html: question.question, fontSize: 17)
                    .id(question.id)
                options(for: question, answer: answer)
                if answer.revealed {
                    ExplainBannerView(
                        correct: answer.correct,
                        answerLabel: question.correctAnswers.joined(separator: "、"),
                        analysis: question.analysis
                    )
                    Button(isLast ? "完成" : "下一题") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            vm.nextQuestion()
                        }
                    }
                    .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        }
    }

    @ViewBuilder
    private func options(for question: BankQuestion, answer: PracticeSession.PracticeAnswer) -> some View {
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
