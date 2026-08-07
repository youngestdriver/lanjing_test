import SwiftUI

/// 题型细分 (subCategory) list for one paper — fetched live on first entry
/// (enter → questions → local classification), with a shuffle toggle.
struct PracticeSubcategoryListView: View {
    @Bindable var vm: PracticeBankViewModel
    let paper: Exam

    var body: some View {
        List {
            Section {
                Toggle("随机顺序", isOn: $vm.isShuffleEnabled)
            } footer: {
                Text("开启后每次练习按随机顺序出题")
            }
            if vm.subcategories.isEmpty {
                if vm.isSubcategoryLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if let error = vm.subcategoryError {
                    Section {
                        ContentUnavailableView {
                            Label("加载失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") {
                                Task { await vm.loadSubcategories(paper: paper) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("该试卷暂无题目", systemImage: "tray")
                        } description: {
                            Text("题目从蓝鲸平台实时获取，若网络异常请重试。")
                        }
                    }
                }
            } else {
                Section("题型") {
                    ForEach(vm.subcategories, id: \.name) { group in
                        NavigationLink(value: PracticeRoute.quiz(paper: paper, subCategory: group.name)) {
                            HStack {
                                Text(group.name)
                                Spacer()
                                Text("\(group.count) 题")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(group.count == 0)
                    }
                }
            }
        }
        .navigationTitle(paper.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.loadSubcategories(paper: paper)
        }
    }
}
