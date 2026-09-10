import SwiftUI

/// 题型细分 (subCategory) list for one category — grouped from the locally
/// crawled bank, with a shuffle toggle that is remembered per 大类.
struct PracticeSubcategoryListView: View {
    let vm: PracticeBankViewModel
    let category: String

    var body: some View {
        Group {
            // 只渲染「归属分类 == 本页分类」且加载完成的题型列表;进入
            // 页面到数据库读取结束之间显示 loading,绝不闪现上一个大类
            // 残留在 vm.subcategories 里的题型行(见 openCategory 注释)。
            if vm.subcategoryCategory == category, !vm.isLoadingSubcategories {
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
            } else {
                loadingView
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.openCategory(category)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载题型…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// This 大类's own shuffle switch, persisted independently.
    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { vm.shuffleEnabled(category: category) },
            set: { vm.setShuffleEnabled($0, category: category) }
        )
    }
}
