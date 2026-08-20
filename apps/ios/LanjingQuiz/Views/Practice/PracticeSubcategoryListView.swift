import SwiftUI

/// 题型细分 (subCategory) list for one category — grouped from the locally
/// crawled bank, with a shuffle toggle that is remembered per 大类.
struct PracticeSubcategoryListView: View {
    let vm: PracticeBankViewModel
    let category: String

    var body: some View {
        List {
            Section {
                Toggle("随机顺序", isOn: shuffleBinding)
            } footer: {
                Text("开启后本大类下每次练习按随机顺序出题；资料分析中共享同一材料的题目会保持在一起")
            }
            Section("题型") {
                ForEach(vm.subcategories, id: \.name) { group in
                    NavigationLink(value: PracticeRoute.quiz(category: category, subCategory: group.name)) {
                        HStack {
                            Text(group.name)
                            Spacer()
                            // 需求 4:做过的题型显示做题进度 x/xx,否则显示题量。
                            let answered = vm.answeredCount(category: category, subCategory: group.name)
                            Text(answered > 0 ? "\(answered)/\(group.count)" : "\(group.count) 题")
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

    /// This 大类's own shuffle switch, persisted independently.
    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { vm.shuffleEnabled(category: category) },
            set: { vm.setShuffleEnabled($0, category: category) }
        )
    }
}
