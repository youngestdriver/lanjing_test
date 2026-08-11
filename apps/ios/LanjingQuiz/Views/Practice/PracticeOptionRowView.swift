import SwiftUI

/// Stateless option row for practice questions (OptionRowView is bound to the
/// exam QuizViewModel, so the styling is ported here). Empty option slots
/// (填空) render as a gray non-tappable placeholder, keeping the answer
/// letters aligned with the original slots. State comes from the session's
/// per-question `answers` — after the data-layer fix the wrongly-tapped
/// option is in `selected`, so it can be marked red (问题 2).
struct PracticeOptionRowView: View {
    let question: BankQuestion
    let letter: String
    /// Current question's per-question state; nil = 未作答.
    let answer: PracticeSession.PracticeAnswer?
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

    private var isAnswered: Bool { answer?.revealed ?? false }
    private var isSelected: Bool { answer?.selected.contains(letter) ?? false }

    /// nil while pending or after a 无答案 reveal (correct == nil) — the row
    /// then falls back to the selected/unselected styling below.
    private var resultMark: QuizLogic.OptionResult? {
        guard isAnswered, let correct = answer?.correct else { return nil }
        return BankLogic.optionResult(isAnswered: true, isSelected: isSelected, isCorrect: isCorrect)
    }

    private var background: Color {
        switch resultMark {
        case .correct: return DS.accent.opacity(0.12)
        case .wrong: return DS.red.opacity(0.12) // 问题 2: 选错的选项标红
        case nil: break
        }
        // Covers both "多选未提交的 pending" and "无答案题已选" — keycap
        // distinguishes them (answered → gray key).
        if isSelected { return DS.blue.opacity(0.12) }
        return Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        switch resultMark {
        case .correct: return DS.accent
        case .wrong: return DS.red
        case nil: break
        }
        if isSelected { return DS.blue }
        return Color(.systemGray4)
    }

    /// Accessibility handle for UI tests: wrong-answered rows get
    /// "option-<letter>-wrong", selected rows "option-<letter>-selected".
    /// The Button's accessible label stays the keycap letter ("A"), so
    /// existing app.buttons["A"]-style lookups are unaffected.
    private var accessibilityID: String {
        if isAnswered, resultMark == .wrong { return "option-\(letter)-wrong" }
        if isSelected { return "option-\(letter)-selected" }
        return ""
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
        .accessibilityIdentifier(accessibilityID)
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
                    // 无答案题已作答: gray key, no verdict mark.
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
