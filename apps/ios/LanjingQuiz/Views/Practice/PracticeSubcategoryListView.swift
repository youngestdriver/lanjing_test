import SwiftUI

/// 题型细分 (subCategory) list for one category — grouped from the locally
/// crawled bank, with a shuffle toggle.
struct PracticeSubcategoryListView: View {
    @Bindable var vm: PracticeBankViewModel
    let category: String

    var body: some View {
        List {
            Section {
                Toggle("随机顺序", isOn: $vm.isShuffleEnabled)
            } footer: {
                Text("开启后每次练习按随机顺序出题")
            }
            Section("题型") {
                ForEach(vm.subcategories, id: \.name) { group in
                    NavigationLink(value: PracticeRoute.quiz(category: category, subCategory: group.name)) {
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
            if vm.subcategories.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("该分类暂无题目", systemImage: "tray")
                    } description: {
                        Text("本地题库可能不完整，请在 我的 > 更新题库 重新爬取。")
                    }
                }
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.openCategory(category)
        }
    }
}
