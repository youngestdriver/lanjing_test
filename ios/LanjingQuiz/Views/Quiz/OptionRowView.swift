import SwiftUI

struct OptionRowView: View {
    let vm: QuizViewModel
    let question: Question
    let letter: String
    var compact = false

    private var optionText: String? {
        let idx = question.letters.firstIndex(of: letter) ?? 0
        guard idx < question.answers.count else { return nil }
        return question.answers[idx]
    }

    private var isSelected: Bool {
        vm.selectionByQuestion[question.id]?.contains(letter) ?? false
    }

    private var isAnswered: Bool {
        vm.answeredIDs.contains(question.id)
    }

    private var isCorrect: Bool {
        question.isCorrectAnswer(letter)
    }

    /// The tapped-wrong state: selected (or confirmed) but not part of the answer.
    private var isTappedWrong: Bool { isAnswered && isSelected && !isCorrect }

    private var background: Color {
        if isCorrect && isAnswered { return DS.accent.opacity(0.12) }
        if isTappedWrong { return DS.red.opacity(0.12) }
        if isSelected && !isAnswered { return DS.blue.opacity(0.12) }
        return Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        if isCorrect && isAnswered { return DS.accent }
        if isTappedWrong { return DS.red }
        if isSelected && !isAnswered { return DS.blue }
        return Color(.systemGray4)
    }

    var body: some View {
        Button {
            vm.tapOption(letter)
        } label: {
            if compact {
                compactTile
            } else {
                HStack(spacing: 12) {
                    keycap
                    if let optionText {
                        HTMLText(html: optionText)
                            .font(.system(size: 16))
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(borderColor, lineWidth: 2))
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
            }
        }
        .buttonStyle(.plain)
        .disabled(isAnswered)
    }

    /// 4 options with ≤2-char texts render as horizontal keycap tiles (SPA .options.row).
    private var compactTile: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DS.radiusSM)
                .fill(background)
                .frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(borderColor, lineWidth: 2))
            if let optionText {
                Text(optionText)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 64, height: 64)
            }
            Text(letter)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(keycapFill)
                .clipShape(Circle())
                .padding(5)
        }
    }

    private var keycap: some View {
        Group {
            if isAnswered {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(keycapFill)
                        .frame(width: 30, height: 30)
                    Image(systemName: keycapIconName)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 2))
                    Text(letter)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(borderColor)
                }
            }
        }
    }

    private var keycapFill: Color {
        if isCorrect { return DS.accent }
        if isTappedWrong { return DS.red }
        return Color(.systemGray4)
    }

    private var keycapIconName: String {
        if isCorrect { return "checkmark" }
        if isTappedWrong { return "xmark" }
        return "checkmark"
    }
}
