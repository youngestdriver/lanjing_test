import SwiftUI

/// Practice quiz screen: header, stem, option rows, multi-select confirm,
/// answer-reveal banner (with remote formula images), next/finish.
struct PracticeQuizView: View {
    let vm: PracticeBankViewModel
    let category: String
    let subCategory: String

    @Environment(\.dismiss) private var dismiss

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
        .task {
            // Always rebuild the session on entry: a stale session from a
            // previous (system-back) exit must never be reused.
            vm.startSession(category: category, subCategory: subCategory)
        }
        .onDisappear {
            vm.endSessionIfCurrent(category: category, subCategory: subCategory)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow(session, question)
                // Comb (资料分析) material stem, rendered above the sub-question.
                if let stem = question.stem, !stem.isEmpty {
                    RichHTMLContent(html: stem, fontSize: 15)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) {
                            Divider()
                        }
                }
                RichHTMLContent(html: question.question, fontSize: 17)
                options(for: question)
                if session.revealed != nil {
                    ExplainBannerView(
                        correct: session.revealed?.correct,
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
    private func options(for question: BankQuestion) -> some View {
        VStack(spacing: 12) {
            ForEach(question.letters, id: \.self) { letter in
                PracticeOptionRowView(
                    question: question,
                    letter: letter,
                    isSelected: session?.selected.contains(letter) ?? false,
                    isAnswered: session?.revealed != nil,
                    onTap: { vm.tapOption(letter) }
                )
            }
        }
        if question.isMulti, session?.revealed == nil, !(session?.selected.isEmpty ?? true) {
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
