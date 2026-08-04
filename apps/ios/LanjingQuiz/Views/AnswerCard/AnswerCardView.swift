import SwiftUI

/// Bottom bar (stats + 答题卡 + 交卷); the answer card itself opens as a sheet —
/// on the web it is a sidebar/bottom bar, native it maps to a sheet (SPA .quiz-sidebar).
struct AnswerCardView: View {
    let vm: QuizViewModel
    @State private var showSheet = false

    var body: some View {
        StatsBarView(vm: vm, showSheet: $showSheet)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .sheet(isPresented: $showSheet) {
                AnswerCardSheet(vm: vm)
            }
    }
}

struct AnswerCardSheet: View {
    let vm: QuizViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionTabsView(vm: vm)
                AnswerDotGrid(vm: vm)
            }
            .navigationTitle("答题卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
