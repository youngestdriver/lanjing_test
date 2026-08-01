import SwiftUI

struct ExamListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: ExamListViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    content(vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("考试列表")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(appState.theme.toggleLabel) {
                        appState.toggleTheme()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出") {
                        appState.logout()
                    }
                }
            }
        }
        .task {
            if vm == nil { vm = ExamListViewModel(appState: appState) }
            await vm?.load()
        }
    }

    private func content(_ vm: ExamListViewModel) -> some View {
        Group {
            if vm.isLoading && vm.exams.isEmpty {
                ProgressView()
            } else if let errorMessage = vm.errorMessage, vm.exams.isEmpty {
                VStack(spacing: 16) {
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await vm.load() }
                    }
                    .buttonStyle(KeycapButtonStyle(color: DS.accent))
                    .frame(width: 160)
                }
                .padding()
            } else if vm.exams.isEmpty {
                Text("没有考试")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(vm.grouped.enumerated()), id: \.offset) { _, group in
                        Section(header: Text(group.style)) {
                            ForEach(group.exams) { exam in
                                ExamCardView(vm: vm, exam: exam)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await vm.load() }
            }
        }
    }
}
