import SwiftUI

struct OptionRowView: View {
    let vm: QuizViewModel
    let question: Question
    let letter: String
    var compact = false
    /// Image-based options (isImageOptions): render the letter tile only.
    var imageOnly = false

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

    private var questionResult: QuestionState.State? {
        vm.states.first { $0.questionsId == question.id }?.state
    }

    /// Result marker for this option after the answer is submitted. The
    /// selected wrong option takes precedence over the reference-answer marker;
    /// every other non-reference option remains an ordinary letter.
    private var resultMark: QuizLogic.OptionResult? {
        QuizLogic.optionResult(
            isAnswered: isAnswered,
            isSelected: isSelected,
            isCorrect: isCorrect,
            isMulti: question.isMulti,
            questionState: questionResult
        )
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
        Button {
            vm.tapOption(letter)
        } label: {
            if imageOnly {
                letterTile
            } else if compact {
                compactTile
            } else {
                HStack(alignment: .top, spacing: 12) {
                    keycap
                    if let optionText {
                        RichHTMLContent(html: optionText)
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

    /// 52pt letter-only tile for image-based options; state conveyed by color.
    private var letterTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .fill(background)
                .frame(width: 52, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusMD)
                        .stroke(borderColor, lineWidth: 2)
                )
            Text(letter)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(tileTextColor)
        }
    }

    /// 4 options with ≤2-char texts render as horizontal keycap tiles pinned at the
    /// bottom (SPA .options.row). Shows the STRIPPED text centered — the raw option
    /// HTML would display literal tags like <p>圆</p>.
    private var compactTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusSM)
                .fill(background)
                .frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(borderColor, lineWidth: 2))
            if let optionText {
                Text(Question.plainText(optionText))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tileTextColor)
                    .frame(width: 64, height: 64)
            }
        }
    }

    private var tileTextColor: Color {
        if resultMark != nil { return .white }
        if isSelected && !isAnswered { return DS.blue }
        return .primary
    }

    private var keycap: some View {
        Group {
            if isAnswered {
                if let resultMark {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(keycapFill)
                            .frame(width: 30, height: 30)
                        Image(systemName: resultMark == .correct ? "checkmark" : "xmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                } else {
                    // Leave unselected, incorrect options unchanged after the
                    // answer is revealed; only the correct answer and a tapped
                    // wrong answer receive result icons.
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

    /// Must only colorize after answering — otherwise the correct answer would be
    /// visibly highlighted on unanswered questions.
    private var keycapFill: Color {
        switch resultMark {
        case .correct: return DS.accent
        case .wrong: return DS.red
        default: return Color(.systemGray4)
        }
    }
}
