import SwiftUI

struct StatsBarView: View {
    let vm: QuizViewModel
    @Binding var showSheet: Bool
    @State private var showSubmitConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Label("\(vm.stats.right)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DS.accent)
                Label("\(vm.stats.error)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(DS.red)
                Label("\(vm.stats.unanswered)", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .bold))
            Spacer()
            Button {
                showSheet = true
            } label: {
                Text("答题卡")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if vm.isSubmitting {
                ProgressView()
            } else {
                Button("交卷") {
                    showSubmitConfirm = true
                }
                .buttonStyle(KeycapButtonStyle(color: DS.red, radius: DS.radiusSM))
                .frame(width: 92, height: 44)
            }
        }
        .confirmationDialog("确定提交试卷吗？", isPresented: $showSubmitConfirm, titleVisibility: .visible) {
            Button("提交", role: .destructive) {
                Task { await vm.submitExam() }
            }
            Button("取消", role: .cancel) {}
        }
    }
}
