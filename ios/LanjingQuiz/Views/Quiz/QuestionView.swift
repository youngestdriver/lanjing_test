import SwiftUI

struct QuestionView: View {
    let vm: QuizViewModel
    let index: Int

    private var question: Question? {
        index < vm.questions.count ? vm.questions[index] : nil
    }

    private var state: QuestionState? {
        index < vm.states.count ? vm.states[index] : nil
    }

    private var isAnswered: Bool {
        question.map { vm.answeredIDs.contains($0.id) } ?? true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let question, let state {
                    headerRow(question, state)
                    HTMLText(html: question.text)
                        .font(.system(size: 17))
                    options(for: question)
                    if isAnswered {
                        explainBanner(for: question, state: state)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headerRow(_ question: Question, _ state: QuestionState) -> some View {
        HStack(spacing: 8) {
            Text(icon(for: state.state))
            Text("第 \(state.num) 题")
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
            Spacer()
            Button {
                vm.toggleMark()
            } label: {
                Text("🔖")
                    .font(.system(size: 16))
                    .opacity(state.marked ? 1 : 0.35)
            }
        }
    }

    @ViewBuilder
    private func options(for question: Question) -> some View {
        if question.isCompactLayout {
            HStack(spacing: 10) {
                ForEach(question.letters, id: \.self) { letter in
                    OptionRowView(vm: vm, question: question, letter: letter, compact: true)
                }
            }
        } else {
            VStack(spacing: 12) {
                ForEach(question.letters, id: \.self) { letter in
                    OptionRowView(vm: vm, question: question, letter: letter, compact: false)
                }
            }
        }
        if question.isMulti, !isAnswered, !(vm.selectionByQuestion[question.id]?.isEmpty ?? true) {
            Button("提交") {
                vm.confirmSelection()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
            .padding(.top, 4)
        }
    }

    private func explainBanner(for question: Question, state: QuestionState) -> some View {
        let correct = state.state == .right
        let answerLabel = question.correctAnswers.isEmpty
            ? question.firstAnswer
            : question.correctAnswers.joined(separator: "、")
        return VStack(alignment: .leading, spacing: 10) {
            Text(correct ? "🦉 棒极了！回答正确！" : "🦉 加油！再接再厉！")
                .font(.system(size: 15, weight: .heavy))
            if !correct {
                Text("正确答案：\(answerLabel)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.accent)
            }
            if let analysis = question.analysis, !analysis.isEmpty {
                HTMLText(html: analysis)
                    .font(.system(size: 14))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((correct ? DS.accent : DS.red).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusMD))
    }

    private func icon(for state: QuestionState.State) -> String {
        switch state {
        case .right: "✅"
        case .error: "❌"
        case .unanswered: "⬜"
        }
    }
}
