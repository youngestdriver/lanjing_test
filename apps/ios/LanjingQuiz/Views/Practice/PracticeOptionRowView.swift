import SwiftUI

/// Stateless option row for practice questions (OptionRowView is bound to the
/// exam QuizViewModel, so the styling is ported here). Empty option slots
/// (填空) render as a gray non-tappable placeholder, keeping the answer
/// letters aligned with the original slots.
struct PracticeOptionRowView: View {
    let question: BankQuestion
    let letter: String
    let isSelected: Bool
    let isAnswered: Bool
    let onTap: () -> Void

    private var optionText: String? {
        let idx = question.letters.firstIndex(of: letter) ?? 0
        guard idx < question.options.count else { return nil }
        return question.options[idx]
    }

    private var isEmptySlot: Bool {
        guard let text = optionText else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isCorrect: Bool {
        question.keys[question.letters.firstIndex(of: letter) ?? 0]
    }

    private var resultMark: QuizLogic.OptionResult? {
        BankLogic.optionResult(isAnswered: isAnswered, isSelected: isSelected, isCorrect: isCorrect)
    }

    private var background: Color {
        switch resultMark {
        case .correct: return DS.accent.opacity(0.12)
        case .wrong: return DS.red.opacity(0.12)
        case nil: break
        }
        if isSelected && !isAnswered { return DS.blue.opacity(0.12) }
        return Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        switch resultMark {
        case .correct: return DS.accent
        case .wrong: return DS.red
        case nil: break
        }
        if isSelected && !isAnswered { return DS.blue }
        return Color(.systemGray4)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                keycap
                if isEmptySlot {
                    Text("（填空）")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                } else if let optionText {
                    RichHTMLContent(
                        html: optionText,
                        fontSize: 16,
                        allowsTextSelection: false
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(borderColor, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
        }
        .buttonStyle(.plain)
        .disabled(isAnswered || isEmptySlot)
    }

    private var keycap: some View {
        Group {
            if isAnswered {
                if let resultMark {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(resultMark == .correct ? DS.accent : DS.red)
                            .frame(width: 30, height: 30)
                        Image(systemName: resultMark == .correct ? "checkmark" : "xmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 30, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(.systemGray4), lineWidth: 2)
                            )
                        Text(letter)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color(.systemGray))
                    }
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
}
