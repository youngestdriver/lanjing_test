import SwiftUI

/// 大类 list with per-category question counts from the local bank meta,
/// plus a footer with crawl info and a manual 更新题库 action.
struct PracticeCategoryListView: View {
    let vm: PracticeBankViewModel

    var body: some View {
        List {
            Section {
                ForEach(BankLogic.categories, id: \.self) { category in
                    let count = vm.meta?.counts?[category] ?? 0
                    NavigationLink(value: PracticeRoute.subcategories(category: category)) {
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(count) 题")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(count == 0)
                }
            } header: {
                Text("题库分类")
            } footer: {
                Text("题目从蓝鲸平台实时爬取并保存在本机，可离线练习；首次进入本页会自动爬取，图片不缓存，展示时从网络加载。")
            }
            if let meta = vm.meta {
                Section {
                    Button("更新题库") {
                        Task { await vm.updateBank() }
                    }
                } footer: {
                    Text("题库版本 round \(meta.round ?? 0) · 共 \(meta.totalCount) 题。重新爬取会跳过已完成的试卷，只补新卷。")
                }
            }
        }
        .navigationTitle("练习")
    }
}
