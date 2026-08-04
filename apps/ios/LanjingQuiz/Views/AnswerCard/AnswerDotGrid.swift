import SwiftUI

/// 36pt question dots: green right / red wrong / blue ring current / 🔖 marked.
/// Filtered by the active section tab; current dot auto-scrolls into view.
struct AnswerDotGrid: View {
    let vm: QuizViewModel

    private var visibleIndices: [Int] {
        vm.states.indices.filter { index in
            guard let section = vm.selectedSection else { return true }
            return vm.states[index].section == section
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 10) {
                    ForEach(visibleIndices, id: \.self) { index in
                        dot(index).id(index)
                    }
                }
                .padding()
            }
            .onChange(of: vm.currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func dot(_ index: Int) -> some View {
        let state = vm.states[index]
        let isCurrent = index == vm.currentIndex
        return Button {
            vm.goTo(index)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text("\(state.num)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(foreground(for: state.state, isCurrent: isCurrent))
                    .frame(width: 36, height: 36)
                    .background(fill(for: state.state))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(border(for: state.state, isCurrent: isCurrent),
                                    lineWidth: isCurrent ? 3 : 1)
                    )
                if state.marked {
                    Text("🔖")
                        .font(.system(size: 10))
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func fill(for state: QuestionState.State) -> Color {
        switch state {
        case .right: DS.accent
        case .error: DS.red
        case .unanswered: Color(.systemGray5)
        }
    }

    private func border(for state: QuestionState.State, isCurrent: Bool) -> Color {
        isCurrent ? DS.blue : Color(.systemGray4)
    }

    private func foreground(for state: QuestionState.State, isCurrent: Bool) -> Color {
        switch state {
        case .right, .error: .white
        case .unanswered: isCurrent ? DS.blue : .secondary
        }
    }
}
