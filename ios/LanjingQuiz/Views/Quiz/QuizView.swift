import SwiftUI

struct QuizView: View {
    @Environment(AppState.self) private var appState
    let exam: Exam
    @State private var vm: QuizViewModel?
    @FocusState private var quizFocused: Bool

    var body: some View {
        Group {
            if let vm {
                content(vm)
            } else {
                ProgressView("加载中…")
            }
        }
        .task {
            if vm == nil { vm = QuizViewModel(exam: exam, appState: appState) }
            await vm?.enterAndLoad()
        }
        .onDisappear { vm?.cancel() }
        .onChange(of: vm?.result) { _, newValue in
            if let result = newValue {
                appState.route = .result(result)
            }
        }
    }

    private var currentIndexBinding: Binding<Int> {
        Binding(
            get: { vm?.currentIndex ?? 0 },
            // Keep swipes and programmatic navigation on the same path so a
            // timer is restarted exactly once for every question change.
            set: { vm?.goTo($0) }
        )
    }

    private func content(_ vm: QuizViewModel) -> some View {
        VStack(spacing: 0) {
            QuizHeaderView(vm: vm)
            if vm.isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    if let phase = vm.loadPhase {
                        Text(phase)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            } else if let errorMessage = vm.errorMessage, vm.questions.isEmpty {
                errorState(errorMessage)
            } else if !vm.questions.isEmpty {
                quizTopBar(vm)
                TabView(selection: currentIndexBinding) {
                    ForEach(Array(vm.states.enumerated()), id: \.offset) { index, _ in
                        QuestionView(vm: vm, index: index)
                            .id(vm.states[index].questionsId)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                AnswerCardView(vm: vm)
            } else {
                Spacer()
                Text("没有题目")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($quizFocused)
        .onKeyPress(phases: .all) { handleKeyPress($0, vm: vm) }
        .onAppear { quizFocused = true }
    }

    private func quizTopBar(_ vm: QuizViewModel) -> some View {
        HStack {
            Text("第 \(vm.currentIndex + 1) / \(vm.totalCount) 题")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            if let section = vm.currentState?.section, !section.isEmpty {
                Text(section)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
            Button("重试") {
                vm?.retry()
                Task { await vm?.enterAndLoad() }
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent))
            .frame(width: 160)
            Button("返回") {
                appState.route = .examList
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - iPad keyboard navigation (SPA index.html:2138-2193)

    private func handleKeyPress(_ press: KeyPress, vm: QuizViewModel) -> KeyPress.Result {
        guard press.phase == .down else { return .ignored }
        if press.key == .upArrow {
            vm.goTo(max(0, vm.currentIndex - 1))
            return .handled
        }
        if press.key == .downArrow {
            vm.goTo(min(vm.currentIndex + 1, max(0, vm.states.count - 1)))
            return .handled
        }
        if press.key == .leftArrow {
            vm.moveSelection(direction: -1)
            return .handled
        }
        if press.key == .rightArrow {
            vm.moveSelection(direction: 1)
            return .handled
        }
        if press.key == .escape {
            vm.clearSelection()
            return .handled
        }
        if press.key == .return {
            vm.submitCurrentSelection()
            return .handled
        }
        for letter in ["A", "B", "C", "D"] {
            if press.key == KeyEquivalent(Character(letter)) || press.key == KeyEquivalent(Character(letter.lowercased())) {
                vm.selectOption(letter)
                return .handled
            }
        }
        return .ignored
    }
}
