import SwiftUI

/// 大类 list with per-category paper counts from the live upstream exam list.
struct PracticeCategoryListView: View {
    let vm: PracticeBankViewModel

    var body: some View {
        List {
            Section {
                ForEach(BankLogic.categories, id: \.self) { category in
                    let count = vm.paperCount(for: category)
                    NavigationLink(value: PracticeRoute.papers(category: category)) {
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(count) 篇试卷")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(count == 0)
                }
            } header: {
                Text("题库分类")
            } footer: {
                Text("题目直接从蓝鲸平台实时获取；进入练习会占用一次作答机会，退出时自动结束本次作答，答案只在本机判分、不会提交。")
            }
        }
        .navigationTitle("练习")
    }
}
